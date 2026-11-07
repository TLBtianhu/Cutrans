//! session.zig — 可实例化的会话 shell 角色与任务栏固定入口
//!
//! State 只拥有会话策略和身份驻留,不拥有应用生命周期;surfaces 通过显式指针
//! 提供通用窗口操作,避免不同会话共享 shell、pin 或保护状态。

const std = @import("std");
const surfaces = @import("surfaces.zig");

pub const State = struct {
    current_shell: ?surfaces.SurfaceRef,
    pin_items: [16]surfaces.SurfaceRef,
    pin_count: usize,
    allocator: std.mem.Allocator,
    surfaces: *surfaces.Registry,

    pub fn init(self: *State, allocator: std.mem.Allocator, registry: *surfaces.Registry) void {
        self.* = .{
            .current_shell = null,
            .pin_items = undefined,
            .pin_count = 0,
            .allocator = allocator,
            .surfaces = registry,
        };
    }

    pub fn reset(self: *State) void {
        if (self.current_shell) |*old| {
            _ = self.surfaces.setProtected(old.owner_kind, old.id, false);
            self.freeRef(old);
        }
        self.current_shell = null;
        for (self.pin_items[0..self.pin_count]) |*ref| self.freeRef(ref);
        self.pin_count = 0;
    }

    pub fn deinit(self: *State) void {
        self.reset();
    }

    fn cloneRef(self: *State, ref: surfaces.SurfaceRef) !surfaces.SurfaceRef {
        return .{ .owner_kind = ref.owner_kind, .id = try self.allocator.dupe(u8, ref.id) };
    }

    fn freeRef(self: *State, ref: *surfaces.SurfaceRef) void {
        self.allocator.free(ref.id);
        ref.id = "";
    }

    pub fn shellRef(self: *const State) ?surfaces.SurfaceRef {
        return self.current_shell;
    }

    pub fn isShell(self: *const State, ref: surfaces.SurfaceRef) bool {
        const current = self.current_shell orelse return false;
        return current.eql(ref);
    }

    pub fn assignShell(self: *State, ref: surfaces.SurfaceRef, protected: bool) bool {
        if (!self.surfaces.exists(ref.owner_kind, ref.id)) return false;
        if (self.current_shell) |old| {
            if (old.eql(ref)) return self.surfaces.setProtected(ref.owner_kind, ref.id, protected);
            const owned = self.cloneRef(ref) catch return false;
            _ = self.surfaces.setProtected(old.owner_kind, old.id, false);
            self.freeRef(&self.current_shell.?);
            self.current_shell = owned;
        } else {
            self.current_shell = self.cloneRef(ref) catch return false;
        }
        return self.surfaces.setProtected(ref.owner_kind, ref.id, protected);
    }

    pub fn clearShell(self: *State) void {
        if (self.current_shell) |*old| {
            _ = self.surfaces.setProtected(old.owner_kind, old.id, false);
            self.freeRef(old);
        }
        self.current_shell = null;
    }

    pub fn activateShell(self: *State) bool {
        const current = self.current_shell orelse return false;
        return self.surfaces.openPreserveFloatingFocus(current.owner_kind, current.id);
    }

    pub fn openShell(self: *State, ref: surfaces.SurfaceRef, protected: bool) bool {
        if (!self.surfaces.open(ref.owner_kind, ref.id)) return false;
        return self.assignShell(ref, protected);
    }

    pub fn pin(self: *State, ref: surfaces.SurfaceRef) bool {
        if (!self.surfaces.exists(ref.owner_kind, ref.id)) return false;
        for (self.pin_items[0..self.pin_count]) |existing| {
            if (existing.eql(ref)) return true;
        }
        if (self.pin_count == self.pin_items.len) return false;
        self.pin_items[self.pin_count] = self.cloneRef(ref) catch return false;
        self.pin_count += 1;
        return true;
    }

    pub fn pinned(self: *const State) []const surfaces.SurfaceRef {
        return self.pin_items[0..self.pin_count];
    }
};

pub fn parseRef(text: []const u8) !surfaces.SurfaceRef {
    const separator = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidSurfaceRef;
    const owner_text = text[0..separator];
    const id = text[separator + 1 ..];
    if (id.len == 0) return error.InvalidSurfaceRef;
    const owner_kind: surfaces.OwnerKind = if (std.mem.eql(u8, owner_text, "app"))
        .app
    else if (std.mem.eql(u8, owner_text, "console"))
        .console
    else
        return error.InvalidSurfaceRef;
    return .{ .owner_kind = owner_kind, .id = id };
}

fn testOpen(_: *anyopaque) bool {
    return true;
}

fn testFailOpen(_: *anyopaque) bool {
    return false;
}

fn testClose(_: *anyopaque) void {}

fn testDraw(_: *anyopaque) void {}

fn registerDummy(registry: *surfaces.Registry, id: []const u8, fails: bool) bool {
    return registry.register(.{
        .owner_kind = .app,
        .id = id,
        .title = "Dummy",
        .open = if (fails) testFailOpen else testOpen,
        .close = testClose,
        .draw = testDraw,
    });
}

test "shell role is replaceable and failure preserves the old role" {
    var token: u8 = 0;
    var registry: surfaces.Registry = undefined;
    registry.init(&token);
    var state: State = undefined;
    state.init(std.testing.allocator, &registry);
    defer {
        state.deinit();
        registry.deinit();
    }
    try std.testing.expect(registerDummy(&registry, "desktop", false));
    try std.testing.expect(registerDummy(&registry, "other", true));
    const desktop = surfaces.SurfaceRef{ .owner_kind = .app, .id = "desktop" };
    const other = surfaces.SurfaceRef{ .owner_kind = .app, .id = "other" };
    try std.testing.expect(state.openShell(desktop, true));
    try std.testing.expect(state.isShell(desktop));
    try std.testing.expect(registry.isProtected(.app, "desktop"));
    try std.testing.expect(!state.openShell(other, true));
    try std.testing.expect(state.isShell(desktop));
    try std.testing.expect(registry.isActiveFull(.app, "desktop"));
    try std.testing.expect(!registry.close(.app, "desktop"));
}

test "session owns shell and pin identities after caller mutation" {
    var token: u8 = 0;
    var registry: surfaces.Registry = undefined;
    registry.init(&token);
    var state: State = undefined;
    state.init(std.testing.allocator, &registry);
    defer {
        state.deinit();
        registry.deinit();
    }
    try std.testing.expect(registerDummy(&registry, "editor", false));
    var buf: [16]u8 = undefined;
    @memcpy(buf[0..10], "app:editor");
    const ref = try parseRef(buf[0..10]);
    try std.testing.expect(state.pin(ref));
    try std.testing.expect(state.openShell(ref, true));
    buf[0] = 'X';
    try std.testing.expectEqualStrings("editor", state.shellRef().?.id);
    try std.testing.expectEqualStrings("editor", state.pinned()[0].id);
}

test "pins deduplicate and parse owner-qualified refs" {
    var token: u8 = 0;
    var registry: surfaces.Registry = undefined;
    registry.init(&token);
    var state: State = undefined;
    state.init(std.testing.allocator, &registry);
    defer {
        state.deinit();
        registry.deinit();
    }
    try std.testing.expect(registerDummy(&registry, "editor", false));
    const ref = try parseRef("app:editor");
    try std.testing.expect(state.pin(ref));
    try std.testing.expect(state.pin(ref));
    try std.testing.expectEqual(@as(usize, 1), state.pinned().len);
    try std.testing.expect(!state.pin(.{ .owner_kind = .app, .id = "missing" }));
    try std.testing.expectError(error.InvalidSurfaceRef, parseRef("other:editor"));
    try std.testing.expectError(error.InvalidSurfaceRef, parseRef("editor"));
}
