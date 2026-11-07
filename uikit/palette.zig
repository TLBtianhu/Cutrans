//! Cutrans 的纯数据色彩真源。两套 Shell 各自适配绘图库,不互相依赖。
//! 深靛蓝工作底色,冰蓝/淡紫强调,暖金只用于少量提示。

pub const background: u24 = 0x0d1024;
pub const surface: u24 = 0x171d39;
pub const surface_top: u24 = 0x232d4e;
pub const surface_bottom: u24 = 0x141a32;
pub const surface_hover: u24 = 0x26315a;
pub const selection: u24 = 0x2a365e;
pub const border: u24 = 0x354265;
pub const highlight: u24 = 0x8095c3;
pub const text: u24 = 0xe7ecff;
pub const muted: u24 = 0xa3afcc;
pub const caption: u24 = 0x8796b8;
pub const accent: u24 = 0xa4bcff;
pub const accent_hover: u24 = 0xbcd1ff;
pub const accent_pressed: u24 = 0x899bea;
pub const violet: u24 = 0xa392f8;
pub const gold: u24 = 0xf3c889;
pub const ink: u24 = 0x10152c;
pub const danger: u24 = 0xf18c9f;
pub const danger_hover: u24 = 0xffa6b5;
pub const danger_pressed: u24 = 0xd66f87;
pub const success: u24 = 0x8bc9b5;
pub const brand_tl: u24 = 0x303e6a;
pub const brand_tr: u24 = 0x302b58;
pub const brand_bl: u24 = 0x1d294b;
pub const brand_br: u24 = 0x211e40;

pub fn rgba(comptime value: u24, comptime alpha: f32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((value >> 16) & 0xff)) / 255,
        @as(f32, @floatFromInt((value >> 8) & 0xff)) / 255,
        @as(f32, @floatFromInt(value & 0xff)) / 255,
        alpha,
    };
}

// 固定小图由代码生成并进 NanoUI 静态图集,不会逐帧上传背景或读取外部资产。
pub const material_width = 16;
pub const material_height = 64;
pub const backdrop_bgra = gradient(0x20294b, 0x171b38, background, background);
pub const panel_bgra = gradient(surface_top, 0x202641, surface_bottom, surface_bottom);

fn gradient(comptime tl: u24, comptime tr: u24, comptime bl: u24, comptime br: u24) [material_width * material_height * 4]u8 {
    @setEvalBranchQuota(100_000);
    var bytes: [material_width * material_height * 4]u8 = undefined;
    for (0..material_height) |y| {
        const ty = @as(f32, @floatFromInt(y)) / (material_height - 1);
        for (0..material_width) |x| {
            const tx = @as(f32, @floatFromInt(x)) / (material_width - 1);
            inline for (.{ 0, 8, 16 }, 0..) |shift, channel| {
                const a = @as(f32, @floatFromInt((tl >> shift) & 0xff));
                const b = @as(f32, @floatFromInt((tr >> shift) & 0xff));
                const c = @as(f32, @floatFromInt((bl >> shift) & 0xff));
                const d = @as(f32, @floatFromInt((br >> shift) & 0xff));
                bytes[(y * material_width + x) * 4 + channel] = @intFromFloat(@round((a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty));
            }
            bytes[(y * material_width + x) * 4 + 3] = 255;
        }
    }
    return bytes;
}
