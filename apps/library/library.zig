const std = @import("std");
const RuntimeContext = @import("runtime").context.Context;
const panel = @import("panel.zig");

const LibraryState = struct {
    assets: panel.State,
};

fn state(ctx: *RuntimeContext) *LibraryState {
    return @ptrCast(@alignCast(ctx.library_state.?));
}

pub fn setDialogOwner(ctx: *RuntimeContext, owner: ?*anyopaque) void {
    if (ctx.library_state != null) state(ctx).assets.dialog_owner = owner;
}

pub fn open(ptr: *anyopaque) bool {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(ptr));
    if (ctx.library_state == null) {
        const library_state = ctx.allocator.create(LibraryState) catch return false;
        library_state.* = .{ .assets = .{} };
        ctx.library_state = library_state;
    }
    std.debug.print("[app] library.open\n", .{});
    return true;
}

pub fn close(ptr: *anyopaque) void {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(ptr));
    if (ctx.library_state) |ptr_state| {
        const library_state: *LibraryState = @ptrCast(@alignCast(ptr_state));
        library_state.assets.deinit(ctx);
        ctx.allocator.destroy(library_state);
        ctx.library_state = null;
    }
    std.debug.print("[app] library.close\n", .{});
}

pub fn draw(ptr: *anyopaque) void {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(ptr));
    if (ctx.library_state == null) return;
    const size = @import("zgui").io.getDisplaySize();
    panel.draw(ctx, &state(ctx).assets, 24, 24, size[0] - 48, size[1] - 48);
}

pub fn verifyPackExample(ctx: *RuntimeContext) !void {
    if (ctx.library_state == null) return error.LibraryNotOpen;
    try panel.verifyPackExample(ctx, &state(ctx).assets);
}
