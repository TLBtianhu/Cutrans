//! widgets.zig — 预设控件(Controls/ControlTemplate 位)
//!
//! 只回答“某类控件怎么画”:按钮、导航胶囊、卡片、列表条目。
//! 设计令牌归 theme.zig;低层画笔归 paint.zig;声明与排版归 node.zig。

const std = @import("std");
const zgui = @import("zgui");
const anim = @import("anim.zig");
const paint = @import("paint.zig");
const tokens = @import("theme.zig");
const theme = tokens.theme;

pub const ButtonKind = enum { primary, secondary, ghost, destructive };

fn actionButton(id: [:0]const u8, text: [:0]const u8, w: f32, h: f32, kind: ButtonKind) bool {
    var label_buf: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{s}###{s}", .{ text, id }) catch return false;
    label_buf[label.len] = 0;
    const t = anim.hoverPeek(id);
    const pos = zgui.getCursorPos();
    const box = paint.scaledBox(id, w, h);
    if (kind != .ghost) paint.softShadow(zgui.getWindowDrawList(), zgui.getCursorScreenPos(), box.w, box.h, theme.r_s);

    const bg = switch (kind) {
        .primary => paint.lerpColor(theme.accent_deep, theme.accent, t),
        .secondary => paint.lerpColor(theme.card_top, theme.hover_bg, t),
        .ghost => paint.lerpColor(.{ 0, 0, 0, 0 }, theme.hover_bg, t),
        .destructive => paint.lerpColor(theme.danger, theme.danger_h, t),
    };
    const fg = switch (kind) {
        .primary, .destructive => theme.ink,
        else => paint.lerpColor(theme.text, theme.accent, t),
    };
    if (kind != .ghost) {
        paint.metalSurface(zgui.getWindowDrawList(), zgui.getCursorScreenPos(), box.w, box.h, theme.r_s, paint.lerpColor(bg, theme.white, 0.06), bg, if (kind == .secondary) theme.border_l else theme.highlight);
    }
    zgui.pushStyleVar1f(.{ .idx = .frame_rounding, .v = theme.r_s });
    zgui.pushStyleVar1f(.{ .idx = .frame_border_size, .v = 0 });
    const fill = if (kind == .ghost) bg else [4]f32{ 0, 0, 0, 0 };
    zgui.pushStyleColor4f(.{ .idx = .button, .c = fill });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = fill });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = fill });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = fg });
    const clicked = zgui.button(label_buf[0..label.len :0], .{ .w = box.w, .h = box.h });
    zgui.popStyleColor(.{ .count = 4 });
    zgui.popStyleVar(.{ .count = 2 });
    anim.hoverDrive(id, zgui.isItemHovered(.{}));
    anim.scaleDrive(id, zgui.isItemActive());
    zgui.setCursorPos(pos);
    zgui.dummy(.{ .w = w, .h = h });
    return clicked;
}

pub fn primaryButton(id: [:0]const u8, text: [:0]const u8, w: f32, h: f32) bool {
    return actionButton(id, text, w, h, .primary);
}

pub fn secondaryButton(id: [:0]const u8, text: [:0]const u8, w: f32, h: f32) bool {
    return actionButton(id, text, w, h, .secondary);
}

pub fn ghostButton(id: [:0]const u8, text: [:0]const u8, w: f32, h: f32) bool {
    return actionButton(id, text, w, h, .ghost);
}

pub fn destructiveButton(id: [:0]const u8, text: [:0]const u8, w: f32, h: f32) bool {
    return actionButton(id, text, w, h, .destructive);
}

/// 启动大按钮:靛蓝金属面与细高光,主标题+副题两行。
pub fn launchButton(id: [:0]const u8, title: [:0]const u8, sub: [:0]const u8, w: f32, h: f32) bool {
    const t = anim.hoverPeek(id);
    const box = paint.scaledBox(id, w, h);
    const pos = zgui.getCursorPos();
    const sp = zgui.getCursorScreenPos();
    const dl = zgui.getWindowDrawList();
    paint.softShadow(dl, sp, box.w, box.h, theme.r_s + 1);
    const fg = paint.lerpColor(theme.accent_deep, theme.accent, t);
    paint.metalSurface(dl, sp, box.w, box.h, theme.r_m, paint.lerpColor(theme.card_top, theme.hover_bg, t), theme.card_bottom, theme.border_l);
    const clicked = zgui.invisibleButton(id, .{ .w = box.w, .h = box.h, .flags = .{ .enable_nav = true } });
    const hovered = zgui.isItemHovered(.{});
    const active = zgui.isItemActive();
    paint.pushFontSize(theme.f_title);
    const tw1 = zgui.calcTextSize(title, .{})[0];
    zgui.setCursorPos(.{ pos[0] + @max(0, (box.w - tw1) / 2), pos[1] + 9 });
    zgui.textColored(fg, "{s}", .{title});
    paint.popFontSize(theme.f_title);
    paint.pushFontSize(theme.f_small);
    const tw2 = zgui.calcTextSize(sub, .{})[0];
    zgui.setCursorPos(.{ pos[0] + @max(0, (box.w - tw2) / 2), pos[1] + h - 26 });
    zgui.textColored(theme.dim, "{s}", .{sub});
    paint.popFontSize(theme.f_small);
    anim.hoverDrive(id, hovered);
    anim.scaleDrive(id, active);
    zgui.setCursorPos(pos);
    zgui.dummy(.{ .w = w, .h = h });
    return clicked;
}

/// 顶栏胶囊:图标+文字成组居中;品牌栏用反白,工作栏用中性前景。
/// 收尾恢复光标并垫全尺寸 dummy,避免 sameLine 链逐颗下沉。
pub fn navPill(id: [:0]const u8, icon: [:0]const u8, text: [:0]const u8, selected: bool, w: f32, on_accent: bool) bool {
    const h = theme.nav_h;
    const t = anim.hoverPeek(id);
    const pos = zgui.getCursorPos();
    const sp = zgui.getCursorScreenPos();
    const dl = zgui.getWindowDrawList();
    const hover = if (on_accent) [4]f32{ 0.65, 0.72, 1, 0.12 } else theme.hover_bg;
    const bgc = if (selected) theme.selection else paint.lerpColor(.{ 0, 0, 0, 0 }, hover, t);
    if (selected) {
        dl.addRectFilled(.{ .pmin = .{ sp[0], sp[1] + 1 }, .pmax = .{ sp[0] + w, sp[1] + h + 1 }, .col = paint.pack(.{ 0.05, 0.15, 0.4, 0.12 }), .rounding = theme.r_pill });
    }
    dl.addRectFilled(.{ .pmin = sp, .pmax = .{ sp[0] + w, sp[1] + h }, .col = paint.pack(bgc), .rounding = theme.r_pill });
    const clicked = zgui.invisibleButton(id, .{ .w = w, .h = h, .flags = .{ .enable_nav = true } });
    const hovered = zgui.isItemHovered(.{});
    paint.pushFontSize(theme.f_nav);
    const fg = if (selected) theme.accent_h else theme.text;
    const iw = zgui.calcTextSize(icon, .{})[0];
    const tw = zgui.calcTextSize(text, .{})[0];
    const total = iw + 6 + tw;
    var tx = pos[0] + @max(0, (w - total) / 2);
    const ty = pos[1] + (h - zgui.getFontSize() * 1.3) / 2 + 1.5;
    zgui.setCursorPos(.{ tx, ty + 2 });
    zgui.textColored(fg, "{s}", .{icon});
    tx += iw + 6;
    zgui.setCursorPos(.{ tx, ty });
    zgui.textColored(fg, "{s}", .{text});
    paint.popFontSize(theme.f_nav);
    anim.hoverDrive(id, hovered);
    zgui.setCursorPos(pos);
    zgui.dummy(.{ .w = w, .h = h });
    return clicked;
}

/// 卡片:低对比金属渐变、圆角与一像素反光边缘。
pub fn cardBegin(id: [:0]const u8, w: f32, h: f32) bool {
    const sp = zgui.getCursorScreenPos();
    paint.softShadow(zgui.getWindowDrawList(), sp, w, h, theme.r_m);
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = .{ 0, 0, 0, 0 } });
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = theme.r_m });
    const visible = zgui.beginChild(id, .{ .w = w, .h = h });
    if (visible) paint.metalSurface(zgui.getWindowDrawList(), zgui.getWindowPos(), w, h, theme.r_m, theme.card_top, theme.card_bottom, theme.border_l);
    return visible;
}
pub fn cardEnd() void {
    zgui.endChild();
    zgui.popStyleVar(.{});
    zgui.popStyleColor(.{});
}

/// 列表条目:单行/双行度量统一取 theme;隐形按钮铺底管命中。
pub fn listItem(id: [:0]const u8, icon: [:0]const u8, title: [:0]const u8, info: [:0]const u8, selected: bool, w: f32) bool {
    const two = info.len > 0;
    const h = if (two) theme.list_double else theme.list_single;
    const t = anim.hoverPeek(id);
    const pos = zgui.getCursorPos();
    const sp = zgui.getCursorScreenPos();
    const dl = zgui.getWindowDrawList();

    const bgc = if (selected) theme.selection else paint.lerpColor(.{ 0, 0, 0, 0 }, theme.hover_bg, t);
    dl.addRectFilled(.{ .pmin = sp, .pmax = .{ sp[0] + w, sp[1] + h }, .col = paint.pack(bgc), .rounding = theme.r_s });
    if (selected) {
        dl.addRectFilled(.{ .pmin = .{ sp[0] + 1, sp[1] + 4 }, .pmax = .{ sp[0] + 4, sp[1] + h - 4 }, .col = paint.pack(theme.accent), .rounding = 1.5 });
    }

    zgui.setCursorPos(pos);
    const clicked = zgui.invisibleButton(id, .{ .w = w, .h = h, .flags = .{ .enable_nav = true } });
    const hovered = zgui.isItemHovered(.{});

    const fg = if (selected) theme.accent else theme.text;
    var tx = pos[0] + theme.g3;
    if (icon.len > 0) {
        zgui.setCursorPos(.{ tx, pos[1] + (h - 24) / 2 + 1 });
        zgui.textColored(if (selected) theme.accent else theme.dim, "{s}", .{icon});
        tx += 30;
    }
    if (two) {
        zgui.setCursorPos(.{ tx, pos[1] + 8 });
        zgui.textColored(fg, "{s}", .{title});
        zgui.setCursorPos(.{ tx, pos[1] + 38 });
        paint.pushFontSize(theme.f_small);
        zgui.textColored(theme.dim, "{s}", .{info});
        paint.popFontSize(theme.f_small);
    } else {
        zgui.setCursorPos(.{ tx, pos[1] + (h - 24) / 2 });
        zgui.textColored(fg, "{s}", .{title});
    }

    anim.hoverDrive(id, hovered);
    zgui.setCursorPos(pos);
    zgui.dummy(.{ .w = w, .h = h + theme.list_tail });
    return clicked;
}
