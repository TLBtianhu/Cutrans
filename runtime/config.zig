//! config.zig — 可实例化的运行配置与资产解析

const std = @import("std");
const assets = @import("assets");
const noto_sans_sc = assets.noto_sans_sc;
const zh_cn = assets.zh_cn;

pub const Config = struct {
    font_main: []const u8 = "NotoSansSC",
    locale: []const u8 = "zh-CN",

    pub fn setFontMain(self: *Config, name: []const u8) !void {
        if (!std.mem.eql(u8, name, "NotoSansSC")) return error.UnknownFontAsset;
        self.font_main = "NotoSansSC";
    }

    pub fn setLocale(self: *Config, name: []const u8) !void {
        if (!std.mem.eql(u8, name, "zh-CN")) return error.UnsupportedLocale;
        self.locale = "zh-CN";
    }

    pub fn mainFont(self: *const Config) ![]const u8 {
        if (!std.mem.eql(u8, self.font_main, "NotoSansSC")) return error.UnknownFontAsset;
        return noto_sans_sc;
    }

    pub fn localePack(self: *const Config) ![]const u8 {
        if (!std.mem.eql(u8, self.locale, "zh-CN")) return error.UnsupportedLocale;
        return zh_cn;
    }
};
