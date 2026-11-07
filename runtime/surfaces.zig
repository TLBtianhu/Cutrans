//! surfaces.zig — 可实例化的虚拟 Surface 生命周期、配置、命中与焦点
//!
//! Registry 拥有自己的表面表、当前 full、焦点和配置序号。矩形/激活变化发布新
//! serial,应用生成内容后确认;命中统一处理 z 层、工作区和局部坐标。

const std = @import("std");

pub const OwnerKind = enum { app, console };
pub const Mode = enum { full, dock, floating };
pub const Point = struct { x: f32, y: f32 };
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: Rect, point: Point) bool {
        return self.w > 0 and self.h > 0 and
            point.x >= self.x and point.y >= self.y and
            point.x < self.x + self.w and point.y < self.y + self.h;
    }
};
pub const Configuration = struct {
    serial: u64,
    rect: Rect,
    mode: Mode,
    activated: bool,
};
pub const Hit = struct {
    ref: SurfaceRef,
    local: Point,
};
pub const SurfaceRef = struct {
    owner_kind: OwnerKind,
    id: []const u8,

    pub fn eql(a: SurfaceRef, b: SurfaceRef) bool {
        return a.owner_kind == b.owner_kind and std.mem.eql(u8, a.id, b.id);
    }
};

pub const Surface = struct {
    owner_kind: OwnerKind,
    id: []const u8,
    title: [:0]const u8,
    icon: [:0]const u8 = "",
    mode: Mode = .full,
    open: *const fn (*anyopaque) bool,
    close: *const fn (*anyopaque) void,
    draw: *const fn (*anyopaque) void,
    request_focus: ?*const fn (*anyopaque) void = null,
    rect: Rect = .{},
    has_rect: bool = false,
    z: i32 = 0,
    protected: bool = false,
    focused: bool = false,
    is_open: bool = false,
    is_visible: bool = false,
    is_minimized: bool = false,
    activation_serial: u64 = 0,
    configure_serial: u64 = 0,
    presented_serial: u64 = 0,
    content_generation: u64 = 0,
};

pub const Registry = struct {
    items: [16]Surface,
    count: usize,
    active_full: ?usize,
    focused_index: ?usize,
    activation_clock: u64,
    configure_clock: u64,
    ctx: *anyopaque,

    pub fn init(self: *Registry, ctx: *anyopaque) void {
        self.* = .{
            .items = undefined,
            .count = 0,
            .active_full = null,
            .focused_index = null,
            .activation_clock = 0,
            .configure_clock = 0,
            .ctx = ctx,
        };
    }

    pub fn reset(self: *Registry) void {
        self.count = 0;
        self.active_full = null;
        self.focused_index = null;
        self.activation_clock = 0;
        self.configure_clock = 0;
    }

    pub fn deinit(self: *Registry) void {
        for (self.items[0..self.count]) |*surface| {
            if (surface.is_open) surface.close(self.ctx);
            surface.is_open = false;
            surface.is_visible = false;
            surface.is_minimized = false;
            surface.focused = false;
        }
        self.reset();
    }

    fn findIndex(self: *const Registry, kind: OwnerKind, id: []const u8) ?usize {
        for (self.items[0..self.count], 0..) |surface, i| {
            if (surface.owner_kind == kind and std.mem.eql(u8, surface.id, id)) return i;
        }
        return null;
    }

    pub fn exists(self: *const Registry, kind: OwnerKind, id: []const u8) bool {
        return self.findIndex(kind, id) != null;
    }

    pub fn register(self: *Registry, surface: Surface) bool {
        if (self.exists(surface.owner_kind, surface.id) or self.count == self.items.len) return false;
        self.items[self.count] = surface;
        self.items[self.count].protected = false;
        self.items[self.count].focused = false;
        self.items[self.count].is_open = false;
        self.items[self.count].is_visible = false;
        self.items[self.count].is_minimized = false;
        self.items[self.count].activation_serial = 0;
        self.items[self.count].configure_serial = 0;
        self.items[self.count].presented_serial = 0;
        self.items[self.count].content_generation = 0;
        self.items[self.count].has_rect = false;
        self.count += 1;
        return true;
    }

    pub fn all(self: *const Registry) []const Surface {
        return self.items[0..self.count];
    }

    fn insertRecent(buf: []Surface, n: *usize, surface: Surface) void {
        var i: usize = 0;
        while (i < n.* and buf[i].activation_serial >= surface.activation_serial) i += 1;
        if (i == buf.len) return;
        if (n.* < buf.len) n.* += 1;
        var j = n.* - 1;
        while (j > i) : (j -= 1) buf[j] = buf[j - 1];
        buf[i] = surface;
    }

    pub fn recent(self: *const Registry, buf: []Surface) []Surface {
        var n: usize = 0;
        for (self.items[0..self.count]) |surface| {
            if (!surface.is_open or surface.activation_serial == 0) continue;
            insertRecent(buf, &n, surface);
        }
        return buf[0..n];
    }

    pub fn isOpen(self: *const Registry, kind: OwnerKind, id: []const u8) bool {
        const i = self.findIndex(kind, id) orelse return false;
        return self.items[i].is_open;
    }

    pub fn isVisible(self: *const Registry, kind: OwnerKind, id: []const u8) bool {
        const i = self.findIndex(kind, id) orelse return false;
        return self.items[i].is_open and self.items[i].is_visible and !self.items[i].is_minimized;
    }

    pub fn isFocused(self: *const Registry, kind: OwnerKind, id: []const u8) bool {
        const i = self.findIndex(kind, id) orelse return false;
        return self.focused_index == i and self.items[i].focused;
    }

    pub fn isActiveFull(self: *const Registry, kind: OwnerKind, id: []const u8) bool {
        const i = self.findIndex(kind, id) orelse return false;
        return self.items[i].mode == .full and self.active_full == i and self.isVisible(kind, id);
    }

    pub fn hasActiveFull(self: *const Registry) bool {
        const i = self.active_full orelse return false;
        return self.items[i].is_open and self.items[i].is_visible and !self.items[i].is_minimized;
    }

    pub fn isProtected(self: *const Registry, kind: OwnerKind, id: []const u8) bool {
        const i = self.findIndex(kind, id) orelse return false;
        return self.items[i].protected;
    }

    pub fn setProtected(self: *Registry, kind: OwnerKind, id: []const u8, protected: bool) bool {
        const i = self.findIndex(kind, id) orelse return false;
        self.items[i].protected = protected;
        return true;
    }

    pub fn rectOf(self: *const Registry, kind: OwnerKind, id: []const u8) Rect {
        const i = self.findIndex(kind, id) orelse return .{};
        return self.items[i].rect;
    }

    pub fn hasRect(self: *const Registry, kind: OwnerKind, id: []const u8) bool {
        const i = self.findIndex(kind, id) orelse return false;
        return self.items[i].has_rect;
    }

    fn rectForIndex(self: *const Registry, i: usize, work_area: Rect) Rect {
        return if (self.items[i].mode == .full) work_area else self.items[i].rect;
    }

    fn issueConfiguration(self: *Registry, i: usize) void {
        self.configure_clock += 1;
        self.items[i].configure_serial = self.configure_clock;
    }

    pub fn configuration(self: *const Registry, kind: OwnerKind, id: []const u8, work_area: Rect) ?Configuration {
        const i = self.findIndex(kind, id) orelse return null;
        if (!self.items[i].is_open) return null;
        return .{
            .serial = self.items[i].configure_serial,
            .rect = self.rectForIndex(i, work_area),
            .mode = self.items[i].mode,
            .activated = self.isActiveFull(kind, id),
        };
    }

    pub fn configurationSerial(self: *const Registry, kind: OwnerKind, id: []const u8) u64 {
        const i = self.findIndex(kind, id) orelse return 0;
        return self.items[i].configure_serial;
    }

    pub fn ackConfiguration(self: *Registry, kind: OwnerKind, id: []const u8, serial: u64) bool {
        const i = self.findIndex(kind, id) orelse return false;
        if (!self.items[i].is_open or serial == 0 or serial != self.items[i].configure_serial) return false;
        if (self.items[i].presented_serial == serial) return true;
        self.items[i].presented_serial = serial;
        self.items[i].content_generation += 1;
        return true;
    }

    pub fn setRect(self: *Registry, kind: OwnerKind, id: []const u8, rect: Rect) void {
        const i = self.findIndex(kind, id) orelse return;
        if (self.items[i].has_rect and std.meta.eql(self.items[i].rect, rect)) return;
        self.items[i].rect = rect;
        self.items[i].has_rect = true;
        if (self.items[i].is_open) self.issueConfiguration(i);
    }

    fn requestFocus(self: *Registry, i: usize) void {
        if (self.focused_index) |old| {
            if (old < self.count) self.items[old].focused = false;
        }
        self.focused_index = i;
        self.items[i].focused = true;
        if (self.items[i].request_focus) |request| request(self.ctx);
    }

    fn above(self: *const Registry, a: usize, b: usize) bool {
        if (self.items[a].z != self.items[b].z) return self.items[a].z > self.items[b].z;
        if (self.items[a].focused != self.items[b].focused) return self.items[a].focused;
        return a > b;
    }

    fn focusTopmost(self: *Registry) void {
        var best: ?usize = null;
        for (self.items[0..self.count], 0..) |surface, i| {
            if (!surface.is_open or !surface.is_visible or surface.is_minimized or surface.mode == .full) continue;
            if (best == null or self.above(i, best.?)) best = i;
        }
        if (best) |i| {
            self.requestFocus(i);
            return;
        }
        if (self.active_full) |i| {
            if (self.items[i].is_open and self.items[i].is_visible and !self.items[i].is_minimized) {
                self.requestFocus(i);
                return;
            }
        }
        if (self.focused_index) |old| {
            if (old < self.count) self.items[old].focused = false;
        }
        self.focused_index = null;
    }

    fn hitIndex(self: *const Registry, work_area: Rect, point: Point) ?usize {
        var best: ?usize = null;
        for (self.items[0..self.count], 0..) |surface, i| {
            if (surface.mode == .full or !surface.is_open or !surface.is_visible or surface.is_minimized) continue;
            if (!surface.rect.contains(point)) continue;
            if (best == null or self.above(i, best.?)) best = i;
        }
        if (best) |i| return i;
        const full = self.active_full orelse return null;
        if (!self.items[full].is_open or !self.items[full].is_visible or self.items[full].is_minimized) return null;
        return if (work_area.contains(point)) full else null;
    }

    pub fn hitTest(self: *const Registry, work_area: Rect, point: Point) ?Hit {
        const i = self.hitIndex(work_area, point) orelse return null;
        const rect = self.rectForIndex(i, work_area);
        return .{
            .ref = .{ .owner_kind = self.items[i].owner_kind, .id = self.items[i].id },
            .local = .{ .x = point.x - rect.x, .y = point.y - rect.y },
        };
    }

    pub fn focusAt(self: *Registry, work_area: Rect, point: Point) bool {
        const i = self.hitIndex(work_area, point) orelse return false;
        self.requestFocus(i);
        return true;
    }

    pub fn focus(self: *Registry, kind: OwnerKind, id: []const u8) bool {
        const i = self.findIndex(kind, id) orelse return false;
        if (!self.items[i].is_open or !self.items[i].is_visible or self.items[i].is_minimized) return false;
        self.requestFocus(i);
        return true;
    }

    pub fn start(self: *Registry, kind: OwnerKind, id: []const u8) bool {
        const i = self.findIndex(kind, id) orelse return false;
        if (self.items[i].is_open) return true;
        if (self.items[i].mode == .floating and !self.items[i].has_rect and self.items[i].rect.w <= 0) {
            self.items[i].rect = .{ .x = -1, .y = -1, .w = 520, .h = 260 };
        }
        self.items[i].is_open = true;
        self.items[i].is_visible = false;
        self.items[i].is_minimized = false;
        self.items[i].activation_serial = 0;
        if (!self.items[i].open(self.ctx)) {
            self.items[i].is_open = false;
            return false;
        }
        self.issueConfiguration(i);
        return true;
    }

    fn hasFloatingFocus(self: *const Registry) bool {
        const i = self.focused_index orelse return false;
        return self.items[i].mode != .full and self.items[i].is_open and self.items[i].is_visible and !self.items[i].is_minimized;
    }

    fn activateInternal(self: *Registry, kind: OwnerKind, id: []const u8, preserve_floating_focus: bool) bool {
        const i = self.findIndex(kind, id) orelse return false;
        if (!self.items[i].is_open) return false;
        if (self.items[i].mode == .full) {
            if (self.active_full) |old| {
                if (old != i) self.items[old].is_visible = false;
            }
            self.active_full = i;
        }
        self.items[i].is_visible = true;
        self.items[i].is_minimized = false;
        self.activation_clock += 1;
        self.items[i].activation_serial = self.activation_clock;
        self.issueConfiguration(i);
        if (!preserve_floating_focus or !self.hasFloatingFocus()) self.requestFocus(i);
        return true;
    }

    pub fn activate(self: *Registry, kind: OwnerKind, id: []const u8) bool {
        return self.activateInternal(kind, id, false);
    }

    pub fn openPreserveFloatingFocus(self: *Registry, kind: OwnerKind, id: []const u8) bool {
        if (!self.start(kind, id)) return false;
        return self.activateInternal(kind, id, true);
    }

    pub fn open(self: *Registry, kind: OwnerKind, id: []const u8) bool {
        if (!self.start(kind, id)) return false;
        return self.activateInternal(kind, id, false);
    }

    pub fn hide(self: *Registry, kind: OwnerKind, id: []const u8) bool {
        const i = self.findIndex(kind, id) orelse return false;
        if (!self.items[i].is_open) return false;
        self.items[i].is_visible = false;
        self.items[i].is_minimized = true;
        if (self.active_full == i) self.active_full = null;
        if (self.focused_index == i) self.focusTopmost();
        return true;
    }

    pub fn close(self: *Registry, kind: OwnerKind, id: []const u8) bool {
        const i = self.findIndex(kind, id) orelse return false;
        if (!self.items[i].is_open or self.items[i].protected) return false;
        self.items[i].close(self.ctx);
        self.items[i].is_open = false;
        self.items[i].is_visible = false;
        self.items[i].is_minimized = false;
        self.items[i].activation_serial = 0;
        self.items[i].focused = false;
        if (self.active_full == i) self.active_full = null;
        if (self.focused_index == i) {
            self.focused_index = null;
            self.focusTopmost();
        }
        return true;
    }

    pub fn drawActive(self: *Registry) bool {
        const i = self.active_full orelse return false;
        if (!self.items[i].is_open or !self.items[i].is_visible or self.items[i].is_minimized) return false;
        self.items[i].draw(self.ctx);
        return true;
    }

    fn before(self: *const Registry, a: usize, b: usize) bool {
        if (self.items[a].z != self.items[b].z) return self.items[a].z < self.items[b].z;
        if (self.items[a].focused != self.items[b].focused) return !self.items[a].focused;
        return a < b;
    }

    pub fn drawDocks(self: *Registry) void {
        var order: [16]usize = undefined;
        var n: usize = 0;
        for (self.items[0..self.count], 0..) |surface, i| {
            if (surface.mode == .full or !surface.is_open or !surface.is_visible or surface.is_minimized) continue;
            order[n] = i;
            n += 1;
        }
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const item = order[i];
            var j = i;
            while (j > 0 and self.before(item, order[j - 1])) : (j -= 1) order[j] = order[j - 1];
            order[j] = item;
        }
        for (order[0..n]) |index| self.items[index].draw(self.ctx);
    }
};

var test_open_calls: usize = 0;
var test_close_calls: usize = 0;

fn testOpen(_: *anyopaque) bool {
    test_open_calls += 1;
    return true;
}

fn testFailOpen(_: *anyopaque) bool {
    return false;
}

fn testClose(_: *anyopaque) void {
    test_close_calls += 1;
}

fn testDraw(_: *anyopaque) void {}

fn registerDummy(registry: *Registry, id: []const u8, mode: Mode) bool {
    return registry.register(.{
        .owner_kind = .app,
        .id = id,
        .title = "Dummy",
        .mode = mode,
        .open = testOpen,
        .close = testClose,
        .draw = testDraw,
    });
}

test "full activation preserves background lifecycle and restores existing full" {
    var token: u8 = 0;
    var registry: Registry = undefined;
    registry.init(&token);
    defer registry.deinit();
    test_open_calls = 0;
    test_close_calls = 0;
    try std.testing.expect(registerDummy(&registry, "a", .full));
    try std.testing.expect(registerDummy(&registry, "b", .full));
    try std.testing.expect(registry.open(.app, "a"));
    try std.testing.expect(registry.open(.app, "b"));
    try std.testing.expect(registry.isOpen(.app, "a"));
    try std.testing.expect(!registry.isVisible(.app, "a"));
    try std.testing.expect(registry.isActiveFull(.app, "b"));
    try std.testing.expectEqual(@as(usize, 0), test_close_calls);
    try std.testing.expect(registry.open(.app, "a"));
    try std.testing.expect(registry.isActiveFull(.app, "a"));
    try std.testing.expect(!registry.isVisible(.app, "b"));
    try std.testing.expectEqual(@as(usize, 2), test_open_calls);
    try std.testing.expect(registry.hide(.app, "a"));
    try std.testing.expect(registry.isOpen(.app, "a"));
    try std.testing.expect(!registry.isVisible(.app, "a"));
    try std.testing.expect(registry.activate(.app, "a"));
    try std.testing.expect(registry.isVisible(.app, "a"));
    try std.testing.expect(!registry.items[registry.findIndex(.app, "a").?].is_minimized);
}

test "focus is unique and failed open keeps the current full" {
    var token: u8 = 0;
    var registry: Registry = undefined;
    registry.init(&token);
    defer registry.deinit();
    try std.testing.expect(registerDummy(&registry, "a", .full));
    try std.testing.expect(registry.register(.{
        .owner_kind = .app,
        .id = "bad",
        .title = "Bad",
        .open = testFailOpen,
        .close = testClose,
        .draw = testDraw,
    }));
    try std.testing.expect(registry.open(.app, "a"));
    try std.testing.expect(!registry.open(.app, "bad"));
    try std.testing.expect(registry.isActiveFull(.app, "a"));
    try std.testing.expect(!registry.isOpen(.app, "bad"));
    try std.testing.expect(registerDummy(&registry, "cli", .floating));
    try std.testing.expect(registry.open(.app, "cli"));
    try std.testing.expect(registry.isFocused(.app, "cli"));
    try std.testing.expect(!registry.isFocused(.app, "a"));
    try std.testing.expect(registry.isActiveFull(.app, "a"));
    try std.testing.expect(registry.hide(.app, "cli"));
    try std.testing.expect(registry.isFocused(.app, "a"));
}

test "close only destroys the target and protection rejects ordinary close" {
    var token: u8 = 0;
    var registry: Registry = undefined;
    registry.init(&token);
    defer registry.deinit();
    test_close_calls = 0;
    try std.testing.expect(registerDummy(&registry, "a", .full));
    try std.testing.expect(registerDummy(&registry, "b", .full));
    try std.testing.expect(registry.open(.app, "a"));
    try std.testing.expect(registry.open(.app, "b"));
    try std.testing.expect(registry.close(.app, "a"));
    try std.testing.expect(registry.isActiveFull(.app, "b"));
    try std.testing.expectEqual(@as(usize, 1), test_close_calls);
    try std.testing.expect(registry.setProtected(.app, "b", true));
    try std.testing.expect(!registry.close(.app, "b"));
    try std.testing.expect(registry.isOpen(.app, "b"));
}

test "recent top N is global and a restarted background surface has no old serial" {
    var token: u8 = 0;
    var registry: Registry = undefined;
    registry.init(&token);
    defer registry.deinit();
    try std.testing.expect(registerDummy(&registry, "a", .full));
    try std.testing.expect(registerDummy(&registry, "b", .full));
    try std.testing.expect(registry.open(.app, "a"));
    try std.testing.expect(registry.open(.app, "b"));
    var one: [1]Surface = undefined;
    var items = registry.recent(&one);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("b", items[0].id);
    try std.testing.expect(registry.close(.app, "b"));
    try std.testing.expect(registry.start(.app, "b"));
    items = registry.recent(&one);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("a", items[0].id);
}

test "two registries do not share surfaces or focus" {
    var token: u8 = 0;
    var first: Registry = undefined;
    var second: Registry = undefined;
    first.init(&token);
    second.init(&token);
    defer first.deinit();
    defer second.deinit();
    try std.testing.expect(registerDummy(&first, "a", .full));
    try std.testing.expect(registerDummy(&second, "b", .full));
    try std.testing.expect(first.open(.app, "a"));
    try std.testing.expect(second.open(.app, "b"));
    try std.testing.expect(!first.isOpen(.app, "b"));
    try std.testing.expect(!second.isOpen(.app, "a"));
    try std.testing.expect(first.isFocused(.app, "a"));
    try std.testing.expect(second.isFocused(.app, "b"));
}

test "configuration acknowledgements reject stale serials and are idempotent" {
    var token: u8 = 0;
    var registry: Registry = undefined;
    registry.init(&token);
    defer registry.deinit();
    try std.testing.expect(registerDummy(&registry, "editor", .full));
    try std.testing.expect(registerDummy(&registry, "cli", .floating));
    const work_area = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    try std.testing.expect(registry.open(.app, "editor"));
    const editor_config = registry.configuration(.app, "editor", work_area).?;
    try std.testing.expect(editor_config.activated);
    try std.testing.expect(std.meta.eql(editor_config.rect, work_area));
    try std.testing.expect(!registry.ackConfiguration(.app, "editor", 0));
    try std.testing.expect(registry.ackConfiguration(.app, "editor", editor_config.serial));
    try std.testing.expect(registry.ackConfiguration(.app, "editor", editor_config.serial));
    try std.testing.expectEqual(@as(u64, 1), registry.items[0].content_generation);

    try std.testing.expect(registry.open(.app, "cli"));
    const old_serial = registry.configurationSerial(.app, "cli");
    registry.setRect(.app, "cli", .{ .x = 20, .y = 30, .w = 400, .h = 200 });
    const new_config = registry.configuration(.app, "cli", work_area).?;
    try std.testing.expect(new_config.serial > old_serial);
    try std.testing.expect(!registry.ackConfiguration(.app, "cli", old_serial));
    try std.testing.expect(registry.ackConfiguration(.app, "cli", new_config.serial));
    try std.testing.expectEqual(@as(u64, 1), registry.items[1].content_generation);
}

test "hit testing respects stacking, local coordinates and minimized surfaces" {
    var token: u8 = 0;
    var registry: Registry = undefined;
    registry.init(&token);
    defer registry.deinit();
    try std.testing.expect(registerDummy(&registry, "editor", .full));
    try std.testing.expect(registerDummy(&registry, "cli", .floating));
    try std.testing.expect(registerDummy(&registry, "panel", .floating));
    registry.items[1].z = 10;
    registry.items[2].z = 20;
    try std.testing.expect(registry.open(.app, "editor"));
    try std.testing.expect(registry.open(.app, "cli"));
    try std.testing.expect(registry.open(.app, "panel"));
    registry.setRect(.app, "cli", .{ .x = 100, .y = 100, .w = 200, .h = 100 });
    registry.setRect(.app, "panel", .{ .x = 150, .y = 120, .w = 200, .h = 100 });
    const work_area = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };

    const panel_hit = registry.hitTest(work_area, .{ .x = 160, .y = 140 }).?;
    try std.testing.expectEqualStrings("panel", panel_hit.ref.id);
    try std.testing.expectEqual(@as(f32, 10), panel_hit.local.x);
    try std.testing.expectEqual(@as(f32, 20), panel_hit.local.y);
    const full_hit = registry.hitTest(work_area, .{ .x = 50, .y = 50 }).?;
    try std.testing.expectEqualStrings("editor", full_hit.ref.id);
    try std.testing.expect(registry.hitTest(work_area, .{ .x = 900, .y = 700 }) == null);
    try std.testing.expect(registry.focusAt(work_area, .{ .x = 50, .y = 50 }));
    try std.testing.expect(registry.isFocused(.app, "editor"));

    try std.testing.expect(registry.hide(.app, "panel"));
    const cli_hit = registry.hitTest(work_area, .{ .x = 160, .y = 140 }).?;
    try std.testing.expectEqualStrings("cli", cli_hit.ref.id);
    try std.testing.expect(registry.focusAt(work_area, .{ .x = 160, .y = 140 }));
    try std.testing.expect(registry.isFocused(.app, "cli"));
}

test "rectangles include their top-left edge and exclude their bottom-right edge" {
    const rect = Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    try std.testing.expect(rect.contains(.{ .x = 10, .y = 20 }));
    try std.testing.expect(rect.contains(.{ .x = 109, .y = 69 }));
    try std.testing.expect(!rect.contains(.{ .x = 110, .y = 70 }));
    try std.testing.expect(!(Rect{ .x = 0, .y = 0, .w = 0, .h = 10 }).contains(.{ .x = 0, .y = 0 }));
}
