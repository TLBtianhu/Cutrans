const std = @import("std");
const builtin = @import("builtin");

extern fn CoInitializeEx(reserved: ?*anyopaque, coinit: u32) i32;
extern fn CoUninitialize() void;
extern fn CoCreateInstance(clsid: *const Guid, outer: ?*anyopaque, context: u32, iid: *const Guid, out: *?*anyopaque) i32;
extern fn CoTaskMemFree(pv: ?*anyopaque) void;

const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

const clsid_file_open_dialog = Guid{ .data1 = 0xDC1C5A9C, .data2 = 0xE88A, .data3 = 0x4DDE, .data4 = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 } };
const iid_file_open_dialog = Guid{ .data1 = 0xD57C7288, .data2 = 0xD4AD, .data3 = 0x4768, .data4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 } };

const FileType = extern struct {
    name: [*:0]const u16,
    pattern: [*:0]const u16,
};

const DialogVtbl = extern struct {
    QueryInterface: *const fn (?*anyopaque, *const Guid, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (?*anyopaque) callconv(.c) u32,
    Release: *const fn (?*anyopaque) callconv(.c) u32,
    Show: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32,
    SetFileTypes: *const fn (?*anyopaque, u32, [*]const FileType) callconv(.c) i32,
    SetFileTypeIndex: *const fn (?*anyopaque, u32) callconv(.c) i32,
    GetFileTypeIndex: *const fn (?*anyopaque, *u32) callconv(.c) i32,
    Advise: *const fn (?*anyopaque, ?*anyopaque, *u32) callconv(.c) i32,
    Unadvise: *const fn (?*anyopaque, u32) callconv(.c) i32,
    SetOptions: *const fn (?*anyopaque, u32) callconv(.c) i32,
    GetOptions: *const fn (?*anyopaque, *u32) callconv(.c) i32,
    SetDefaultFolder: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32,
    SetFolder: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32,
    GetFolder: *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetCurrentSelection: *const fn (?*anyopaque, *?*Item) callconv(.c) i32,
    SetFileName: *const fn (?*anyopaque, [*:0]const u16) callconv(.c) i32,
    GetFileName: *const fn (?*anyopaque, *?[*:0]u16) callconv(.c) i32,
    SetTitle: *const fn (?*anyopaque, [*:0]const u16) callconv(.c) i32,
    SetOkButtonLabel: *const fn (?*anyopaque, [*:0]const u16) callconv(.c) i32,
    SetFileNameLabel: *const fn (?*anyopaque, [*:0]const u16) callconv(.c) i32,
    GetResults: *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetSelectedItems: *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32,
};

const Dialog = struct { vtbl: *const DialogVtbl };

const ItemVtbl = extern struct {
    QueryInterface: *const fn (?*anyopaque, *const Guid, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (?*anyopaque) callconv(.c) u32,
    Release: *const fn (?*anyopaque) callconv(.c) u32,
    BindToHandler: *const fn (?*anyopaque, ?*anyopaque, *const Guid, *const Guid, *?*anyopaque) callconv(.c) i32,
    GetParent: *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetDisplayName: *const fn (?*anyopaque, u32, *?[*:0]u16) callconv(.c) i32,
};

const Item = struct { vtbl: *const ItemVtbl };

pub fn validatePngPath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or path.len < 5 or !std.ascii.eqlIgnoreCase(path[path.len - 4 ..], ".png")) return error.InvalidImagePath;
}

pub fn pickPng(allocator: std.mem.Allocator, owner: ?*anyopaque) !?[]u8 {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const apartment = CoInitializeEx(null, 0x2 | 0x4);
    if (apartment < 0) return error.ComApartmentMismatch;
    defer CoUninitialize();
    var instance: ?*anyopaque = null;
    if (CoCreateInstance(&clsid_file_open_dialog, null, 1, &iid_file_open_dialog, &instance) < 0 or instance == null) return error.DialogCreateFailed;
    const dialog: *Dialog = @ptrCast(@alignCast(instance.?));
    defer _ = dialog.vtbl.Release(dialog);
    const filter = [_]FileType{.{
        .name = std.unicode.utf8ToUtf16LeStringLiteral("PNG 图片 (*.png)"),
        .pattern = std.unicode.utf8ToUtf16LeStringLiteral("*.png"),
    }};
    if (dialog.vtbl.SetFileTypes(dialog, filter.len, &filter) < 0) return error.DialogFilterFailed;
    if (dialog.vtbl.SetOptions(dialog, 0x40 | 0x1000 | 0x800 | 0x8) < 0) return error.DialogOptionsFailed;
    if (dialog.vtbl.SetTitle(dialog, std.unicode.utf8ToUtf16LeStringLiteral("选择 PNG 素材")) < 0) return error.DialogTitleFailed;
    const shown = dialog.vtbl.Show(dialog, owner);
    if (shown == @as(i32, @bitCast(@as(u32, 0x800704C7)))) return null;
    if (shown < 0) return error.DialogShowFailed;
    var item: ?*Item = null;
    if (dialog.vtbl.GetCurrentSelection(dialog, &item) < 0 or item == null) return error.DialogSelectionFailed;
    defer _ = item.?.vtbl.Release(item.?);
    var display_path: ?[*:0]u16 = null;
    if (item.?.vtbl.GetDisplayName(item.?, 0x80028000, &display_path) < 0 or display_path == null) return error.DialogPathFailed;
    defer CoTaskMemFree(@ptrCast(display_path));
    const path = try std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(display_path.?));
    errdefer allocator.free(path);
    try validatePngPath(path);
    return path;
}

test "file dialog accepts only absolute PNG paths" {
    try validatePngPath("C:/assets/example.PNG");
    try std.testing.expectError(error.InvalidImagePath, validatePngPath("assets/example.png"));
    try std.testing.expectError(error.InvalidImagePath, validatePngPath("C:/assets/example.jpg"));
}
