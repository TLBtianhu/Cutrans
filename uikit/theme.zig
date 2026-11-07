//! theme.zig — 设计令牌唯一真源(纯数据,零 ImGui/零逻辑)
//!
//! 只放跨控件共享的颜色、字号、间距、尺寸与动画参数。
//! 页面专属布局仍归声明;画笔实现归 paint.zig/widgets.zig。

const palette = @import("palette");

pub fn hex(comptime h: u32, comptime a: f32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((h >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((h >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(h & 0xff)) / 255.0,
        a,
    };
}

pub const theme = struct {
    // 色值来自无绘图库依赖的 palette;这里只适配 ImGui 的浮点颜色。
    pub const text = palette.rgba(palette.text, 1);
    pub const accent = palette.rgba(palette.accent, 1);
    pub const accent_deep = palette.rgba(palette.accent_pressed, 1);
    pub const accent_h = palette.rgba(palette.accent_hover, 1);
    pub const accent_p = palette.rgba(palette.accent_pressed, 1);
    pub const danger = palette.rgba(palette.danger, 1);
    pub const danger_h = palette.rgba(palette.danger_hover, 1);
    pub const danger_p = palette.rgba(palette.danger_pressed, 1);
    pub const bar_tl = palette.rgba(palette.brand_tl, 1);
    pub const bar_tr = palette.rgba(palette.brand_tr, 1);
    pub const bar_bl = palette.rgba(palette.brand_bl, 1);
    pub const bar_br = palette.rgba(palette.brand_br, 1);
    pub const hover_bg = palette.rgba(palette.surface_hover, 1);
    pub const selection = palette.rgba(palette.selection, 1);
    pub const border_l = palette.rgba(palette.border, 1);
    pub const highlight = palette.rgba(palette.highlight, 0.32);
    pub const dim = palette.rgba(palette.muted, 1);
    pub const caption = palette.rgba(palette.caption, 1);
    pub const card = palette.rgba(palette.surface, 1);
    pub const card_top = palette.rgba(palette.surface_top, 1);
    pub const card_bottom = palette.rgba(palette.surface_bottom, 1);
    pub const sidebar_bg = palette.rgba(palette.surface, 1);
    pub const bg = palette.rgba(palette.background, 1);
    pub const ink = palette.rgba(palette.ink, 1);
    pub const warm = palette.rgba(palette.gold, 1);
    pub const violet = palette.rgba(palette.violet, 1);
    pub const white = hex(0xffffff, 1);

    // 字号(逻辑像素,主字体基准 20)
    pub const f_small: f32 = 16;
    pub const f_title: f32 = 22;
    pub const f_nav: f32 = 20;
    pub const f_brand: f32 = 32;

    // 4px 基栅格与圆角
    pub const g1: f32 = 4;
    pub const g2: f32 = 8;
    pub const g3: f32 = 12;
    pub const g4: f32 = 16;
    pub const g6: f32 = 24;
    pub const g8: f32 = 32;
    pub const r_s: f32 = 5;
    pub const r_m: f32 = 8;
    pub const r_pill: f32 = 13.5;

    // 窗口家具与控件度量
    pub const bar_h: f32 = 48;
    pub const sidebar_w: f32 = 320;
    pub const sidebar_shadow_w: f32 = 4;
    pub const nav_item_w: f32 = 120;
    pub const nav_h: f32 = 34;
    pub const window_btn: f32 = 32;
    pub const button_h: f32 = 34;
    pub const list_single: f32 = 48;
    pub const list_double: f32 = 64;
    pub const list_tail: f32 = g2;
    pub const input_extra: f32 = 14;

    // 微阴影与 productive motion:低干扰、短反馈、无过冲
    pub const shadow_a: f32 = 0.18;
    pub const hover_in_ms: f32 = 120;
    pub const hover_out_ms: f32 = 150;
    pub const press_ms: f32 = 80;
    pub const release_ms: f32 = 140;
    pub const press_scale: f32 = 0.98;
    pub const view_ms: f32 = 220;
    pub const view_rise: f32 = 6;
};
