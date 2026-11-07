//! paint.zig — 低层画笔与共享渲染状态(不含任何预设控件)
//!
//! theme.zig 给设计令牌;本文件只提供字体、IME、颜色、阴影、缩放和少量
//! ImGui 几何助手。预设按钮/卡片/列表归 widgets.zig,页面排版归 node.zig。

const std = @import("std");
const zgui = @import("zgui");
const anim = @import("anim.zig");
const theme = @import("theme.zig").theme;

var font_main: ?zgui.Font = null;
var font_bold: ?zgui.Font = null;

pub fn setFont(f: zgui.Font) void {
    font_main = f;
}
pub fn setFontBold(f: zgui.Font) void {
    font_bold = f;
}

/// 输入框激活时由 node.zig 写入,main.zig 每帧喂给 imm32。
pub var ime_anchor: ?[2]f32 = null;

pub fn pushFontSize(size: f32) void {
    if (size > 0) zgui.pushFont(font_main, size);
}
pub fn popFontSize(size: f32) void {
    if (size > 0) zgui.popFont();
}
pub fn pushFontBold(size: f32) void {
    zgui.pushFont(font_bold, size);
}
pub fn popFontBold() void {
    zgui.popFont();
}

/// ImGui 1.92 构造器默认值 + merge(图标并入)与 mult(笔画乘子)两个旋钮。
pub fn fontConfig(merge: bool, mult: f32) zgui.FontConfig {
    return .{
        .name = std.mem.zeroes([40]u8),
        .font_data = null,
        .font_data_size = 0,
        .font_data_owned_by_atlas = false,
        .merge_mode = merge,
        .pixel_snap_h = false,
        .pixel_snap_v = false,
        .oversample_h = 0,
        .oversample_v = 0,
        .ellipsis_char = 0x2026,
        .size_pixels = 0,
        .glyph_ranges = null,
        .glyph_exclude_ranges = null,
        .glyph_offset = .{ 0, 0 },
        .glyph_min_advance_x = 0,
        .glyph_max_advance_x = std.math.inf(f32),
        .glyph_extra_advance_x = 0,
        .font_no = 0,
        .font_loader_flags = 0,
        .rasterizer_multiply = mult,
        .rasterizer_density = 1.0,
        .flags = .{},
        .dst_font = null,
        .font_loader = null,
        .font_loader_data = null,
    };
}

pub fn lerpColor(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
    };
}

pub fn pack(c: [4]f32) u32 {
    return zgui.colorConvertFloat4ToU32(c);
}

/// 初始化所有通用控件,保证编辑器、弹层、输入框与桌面使用相同暗色语义。
pub fn applyStyle() void {
    const style = zgui.getStyle();
    zgui.styleColorsDark(style);
    style.window_rounding = theme.r_m;
    style.child_rounding = theme.r_m;
    style.popup_rounding = theme.r_m;
    style.frame_rounding = theme.r_s;
    style.frame_border_size = 1;
    style.grab_rounding = 3;
    style.setColor(.text, theme.text);
    style.setColor(.text_disabled, theme.dim);
    style.setColor(.window_bg, theme.bg);
    style.setColor(.child_bg, theme.card);
    style.setColor(.popup_bg, theme.card);
    style.setColor(.border, theme.border_l);
    style.setColor(.border_shadow, .{ 0, 0, 0, 0 });
    style.setColor(.frame_bg, theme.bg);
    style.setColor(.frame_bg_hovered, theme.hover_bg);
    style.setColor(.frame_bg_active, theme.selection);
    style.setColor(.title_bg, theme.card_bottom);
    style.setColor(.title_bg_active, theme.card_top);
    style.setColor(.title_bg_collapsed, theme.card_bottom);
    style.setColor(.menu_bar_bg, theme.card);
    style.setColor(.scrollbar_bg, theme.bg);
    style.setColor(.scrollbar_grab, theme.border_l);
    style.setColor(.scrollbar_grab_hovered, theme.caption);
    style.setColor(.scrollbar_grab_active, theme.dim);
    style.setColor(.check_mark, theme.accent);
    style.setColor(.slider_grab, theme.accent);
    style.setColor(.slider_grab_active, theme.accent_h);
    style.setColor(.button, theme.selection);
    style.setColor(.button_hovered, theme.hover_bg);
    style.setColor(.button_active, theme.border_l);
    style.setColor(.header, theme.selection);
    style.setColor(.header_hovered, theme.hover_bg);
    style.setColor(.header_active, theme.border_l);
    style.setColor(.separator, theme.border_l);
    style.setColor(.separator_hovered, theme.accent);
    style.setColor(.separator_active, theme.accent_h);
    style.setColor(.tab, theme.card_bottom);
    style.setColor(.tab_hovered, theme.hover_bg);
    style.setColor(.tab_selected, theme.selection);
    style.setColor(.tab_selected_overline, theme.accent);
    style.setColor(.table_header_bg, theme.card_top);
    style.setColor(.table_border_strong, theme.border_l);
    style.setColor(.table_border_light, theme.card_top);
    style.setColor(.text_link, theme.accent);
    style.setColor(.text_selected_bg, theme.selection);
    style.setColor(.nav_cursor, theme.accent);
    style.setColor(.drag_drop_target, theme.warm);
}

/// 低对比金属面:固定 24 条色带,圆角边缘按圆的内接范围裁切。
/// 只用于卡片和主要控件;列表项继续平涂,避免让密集内容发亮。
pub fn metalSurface(dl: zgui.DrawList, sp: [2]f32, w: f32, h: f32, radius: f32, top: [4]f32, bottom: [4]f32, border: [4]f32) void {
    if (w <= 0 or h <= 0) return;
    const r = @min(radius, @min(w, h) / 2);
    dl.addRectFilled(.{ .pmin = sp, .pmax = .{ sp[0] + w, sp[1] + h }, .col = pack(bottom), .rounding = r });
    const bands = 24;
    for (0..bands) |i| {
        const y0 = h * @as(f32, @floatFromInt(i)) / bands;
        const y1 = h * @as(f32, @floatFromInt(i + 1)) / bands;
        const edge = @min(y0, h - y1);
        const inset = if (edge < r) r - @sqrt(@max(0, r * r - (r - edge) * (r - edge))) else 0;
        dl.addRectFilledMultiColor(.{
            .pmin = .{ sp[0] + inset, sp[1] + y0 },
            .pmax = .{ sp[0] + w - inset, sp[1] + y1 },
            .col_upr_left = pack(lerpColor(top, bottom, y0 / h)),
            .col_upr_right = pack(lerpColor(top, bottom, y0 / h)),
            .col_bot_left = pack(lerpColor(top, bottom, y1 / h)),
            .col_bot_right = pack(lerpColor(top, bottom, y1 / h)),
        });
    }
    dl.addRect(.{ .pmin = sp, .pmax = .{ sp[0] + w, sp[1] + h }, .col = pack(border), .rounding = r, .thickness = 1 });
    if (w > r * 2 + 2) dl.addLine(.{ .p1 = .{ sp[0] + r, sp[1] + 1 }, .p2 = .{ sp[0] + w - r, sp[1] + 1 }, .col = pack(theme.highlight), .thickness = 1 });
}

/// 两层错位圆角矩形模拟半径 3 的微阴影;光源左上,暗影落右下。
pub fn softShadow(dl: zgui.DrawList, sp: [2]f32, w: f32, h: f32, r: f32) void {
    dl.addRectFilled(.{ .pmin = .{ sp[0], sp[1] + 1 }, .pmax = .{ sp[0] + w, sp[1] + h + 2 }, .col = pack(.{ 0, 0, 0, theme.shadow_a }), .rounding = r + 2 });
    dl.addRectFilled(.{ .pmin = .{ sp[0] + 1, sp[1] + 2 }, .pmax = .{ sp[0] + w - 1, sp[1] + h + 2 }, .col = pack(.{ 0, 0, 0, theme.shadow_a }), .rounding = r + 1 });
}

pub fn spaceY(h: f32) void {
    zgui.dummy(.{ .w = 0, .h = h });
}
pub fn leftMargin(x: f32) void {
    zgui.setCursorPosX(x);
}

/// 以控件中心为锚做按下缩放;返回实际绘制框。
pub fn scaledBox(id: [:0]const u8, w: f32, h: f32) struct { w: f32, h: f32 } {
    const s = anim.scalePeek(id);
    if (s >= 0.999) return .{ .w = w, .h = h };
    const pos = zgui.getCursorPos();
    const sw = w * s;
    const sh = h * s;
    zgui.setCursorPos(.{ pos[0] + (w - sw) / 2, pos[1] + (h - sh) / 2 });
    return .{ .w = sw, .h = sh };
}
