//! desktop.zig — 可替换的默认桌面应用;系统任务栏不属于本应用

const std = @import("std");
const views = @import("view.zig");
const shell = @import("shell.zig");
const RuntimeContext = @import("runtime").context.Context;

pub fn open(ptr: *anyopaque) bool {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(ptr));
    if (views.all().len > 0) return true;
    views.init(ctx.allocator) catch |err| {
        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "桌面 CUI 装载失败: {s}", .{@errorName(err)}) catch "桌面 CUI 装载失败";
        ctx.status.set(text);
        std.debug.print("[app] desktop.open 失败: {s}\n", .{@errorName(err)});
        return false;
    };
    std.debug.print("[app] desktop.open:CUI {d} 字节/{d} 视图/{d} 节点\n", .{ views.bytecode_size, views.all().len, views.decoded_nodes });
    return true;
}

pub fn close(_: *anyopaque) void {
    std.debug.print("[app] desktop.close\n", .{});
}

pub fn draw(ptr: *anyopaque) void {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(ptr));
    if (views.all().len == 0) return;
    shell.draw(ctx);
}
