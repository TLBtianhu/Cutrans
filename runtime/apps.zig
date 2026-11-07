//! apps.zig — 业务应用注册与生命周期;所有状态经 RuntimeContext 访问

const std = @import("std");
const surfaces = @import("surfaces.zig");
const Context = @import("context.zig").Context;

pub const App = struct {
    id: []const u8,
    title: [:0]const u8,
    icon: [:0]const u8 = "",
    mode: surfaces.Mode = .full,
    z: i32 = 0,
    open: *const fn (*anyopaque) bool,
    close: *const fn (*anyopaque) void,
    draw: *const fn (*anyopaque) void,
};

pub fn register(ctx: *Context, app: App) bool {
    return ctx.surfaces.register(.{
        .owner_kind = .app,
        .id = app.id,
        .title = app.title,
        .icon = app.icon,
        .mode = app.mode,
        .z = app.z,
        .open = app.open,
        .close = app.close,
        .draw = app.draw,
    });
}

pub fn start(ctx: *Context, id: []const u8) bool {
    return ctx.surfaces.start(.app, id);
}

pub fn open(ctx: *Context, id: []const u8) bool {
    return ctx.surfaces.open(.app, id);
}

pub fn activate(ctx: *Context, id: []const u8) bool {
    return ctx.surfaces.activate(.app, id);
}

pub fn close(ctx: *Context, id: []const u8) bool {
    const was_active = ctx.surfaces.isActiveFull(.app, id);
    if (!ctx.surfaces.close(.app, id)) return false;
    const is_shell = ctx.session.isShell(.{ .owner_kind = .app, .id = id });
    if (was_active and !is_shell and !ctx.surfaces.hasActiveFull()) _ = ctx.session.activateShell();
    return true;
}

pub fn hide(ctx: *Context, id: []const u8) bool {
    const was_active = ctx.surfaces.isActiveFull(.app, id);
    if (!ctx.surfaces.hide(.app, id)) return false;
    const is_shell = ctx.session.isShell(.{ .owner_kind = .app, .id = id });
    if (was_active and !is_shell and !ctx.surfaces.hasActiveFull()) _ = ctx.session.activateShell();
    return true;
}

fn testOpen(_: *anyopaque) bool {
    return true;
}

fn testClose(_: *anyopaque) void {}

fn testDraw(_: *anyopaque) void {}

fn registerDummy(ctx: *Context, id: []const u8) bool {
    return register(ctx, .{
        .id = id,
        .title = "Dummy",
        .open = testOpen,
        .close = testClose,
        .draw = testDraw,
    });
}

test "hiding an active app restores shell but hiding shell stays hidden" {
    var ctx: Context = undefined;
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    try std.testing.expect(registerDummy(&ctx, "desktop"));
    try std.testing.expect(registerDummy(&ctx, "editor"));
    try std.testing.expect(open(&ctx, "desktop"));
    try std.testing.expect(ctx.session.assignShell(.{ .owner_kind = .app, .id = "desktop" }, true));
    try std.testing.expect(open(&ctx, "editor"));
    try std.testing.expect(ctx.surfaces.isActiveFull(.app, "editor"));
    try std.testing.expect(hide(&ctx, "editor"));
    try std.testing.expect(ctx.surfaces.isActiveFull(.app, "desktop"));
    try std.testing.expect(hide(&ctx, "desktop"));
    try std.testing.expect(!ctx.surfaces.hasActiveFull());
    try std.testing.expect(ctx.surfaces.isOpen(.app, "desktop"));
}

test "restoring shell preserves an existing floating focus" {
    var ctx: Context = undefined;
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    try std.testing.expect(registerDummy(&ctx, "desktop"));
    try std.testing.expect(registerDummy(&ctx, "editor"));
    try std.testing.expect(register(&ctx, .{
        .id = "cli",
        .title = "CLI",
        .mode = .floating,
        .open = testOpen,
        .close = testClose,
        .draw = testDraw,
    }));
    try std.testing.expect(open(&ctx, "desktop"));
    try std.testing.expect(ctx.session.assignShell(.{ .owner_kind = .app, .id = "desktop" }, true));
    try std.testing.expect(open(&ctx, "editor"));
    try std.testing.expect(open(&ctx, "cli"));
    try std.testing.expect(ctx.surfaces.isFocused(.app, "cli"));
    try std.testing.expect(close(&ctx, "editor"));
    try std.testing.expect(ctx.surfaces.isActiveFull(.app, "desktop"));
    try std.testing.expect(ctx.surfaces.isFocused(.app, "cli"));
}
