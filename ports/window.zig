//! 原生窗口能力的最小口岸;非 Windows 不伪造原生效果

const builtin = @import("builtin");
const windows = @import("windows.zig");

pub const Rect = extern struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub fn applyImeAnchor(native_window: ?*anyopaque, anchor: ?Rect) void {
    if (builtin.os.tag != .windows) return;
    windows.applyImeAnchor(native_window, anchor);
}

pub fn configureNativeWindow(native_window: ?*anyopaque) void {
    if (builtin.os.tag != .windows) return;
    windows.configureNativeWindow(native_window);
}
