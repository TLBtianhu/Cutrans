const std = @import("std");
const zglfw = @import("zglfw");
const zgui = @import("zgui");
const abi = @import("vne").abi;
const input = @import("vne").input;

fn base(kind: input.Kind) abi.InputEvent {
    return .{
        .struct_size = @sizeOf(abi.InputEvent),
        .abi_version = abi.version,
        .kind = @backingInt(kind),
        .action = @backingInt(input.Action.none),
        .code = 0,
        .mods = 0,
    };
}

pub fn modifiers(value: zglfw.Mods) u8 {
    return @as(u8, @intFromBool(value.shift)) |
        (@as(u8, @intFromBool(value.control)) << 1) |
        (@as(u8, @intFromBool(value.alt)) << 2) |
        (@as(u8, @intFromBool(value.super)) << 3);
}

pub fn semanticKey(key: zglfw.Key) u16 {
    return switch (key) {
        .unknown => 0,
        .space,
        .apostrophe,
        .comma,
        .minus,
        .period,
        .slash,
        .zero,
        .one,
        .two,
        .three,
        .four,
        .five,
        .six,
        .seven,
        .eight,
        .nine,
        .semicolon,
        .equal,
        .a,
        .b,
        .c,
        .d,
        .e,
        .f,
        .g,
        .h,
        .i,
        .j,
        .k,
        .l,
        .m,
        .n,
        .o,
        .p,
        .q,
        .r,
        .s,
        .t,
        .u,
        .v,
        .w,
        .x,
        .y,
        .z,
        .left_bracket,
        .backslash,
        .right_bracket,
        .grave_accent,
        .world_1,
        .world_2,
        .escape,
        .enter,
        .tab,
        .backspace,
        .insert,
        .delete,
        .right,
        .left,
        .down,
        .up,
        .page_up,
        .page_down,
        .home,
        .end,
        .caps_lock,
        .scroll_lock,
        .num_lock,
        .print_screen,
        .pause,
        .F1,
        .F2,
        .F3,
        .F4,
        .F5,
        .F6,
        .F7,
        .F8,
        .F9,
        .F10,
        .F11,
        .F12,
        .F13,
        .F14,
        .F15,
        .F16,
        .F17,
        .F18,
        .F19,
        .F20,
        .F21,
        .F22,
        .F23,
        .F24,
        .F25,
        .kp_0,
        .kp_1,
        .kp_2,
        .kp_3,
        .kp_4,
        .kp_5,
        .kp_6,
        .kp_7,
        .kp_8,
        .kp_9,
        .kp_decimal,
        .kp_divide,
        .kp_multiply,
        .kp_subtract,
        .kp_add,
        .kp_enter,
        .kp_equal,
        .left_shift,
        .left_control,
        .left_alt,
        .left_super,
        .right_shift,
        .right_control,
        .right_alt,
        .right_super,
        .menu,
        => @intCast(@backingInt(key)),
    };
}

pub fn cursorEvent(x: f64, y: f64) !abi.InputEvent {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        x < std.math.minInt(i32) or x > std.math.maxInt(i32) or
        y < std.math.minInt(i32) or y > std.math.maxInt(i32)) return error.InvalidPointerCoordinate;
    var event = base(.pointer_move);
    event.x = @intFromFloat(x);
    event.y = @intFromFloat(y);
    return event;
}

pub fn pointerEvent(button: zglfw.MouseButton, action: zglfw.Action, mods: zglfw.Mods, x: i32, y: i32) abi.InputEvent {
    var event = base(if (action == .release) .pointer_up else .pointer_down);
    event.action = @backingInt(switch (action) {
        .release => input.Action.release,
        .press, .repeat => input.Action.press,
    });
    event.code = @intCast(@backingInt(button) + 1);
    event.mods = modifiers(mods);
    event.x = x;
    event.y = y;
    return event;
}

pub fn keyEvent(key: zglfw.Key, action: zglfw.Action, mods: zglfw.Mods, context: u32) abi.InputEvent {
    var event = base(if (action == .release) .key_up else .key_down);
    event.action = @backingInt(switch (action) {
        .release => input.Action.release,
        .press => input.Action.press,
        .repeat => input.Action.repeat,
    });
    event.code = semanticKey(key);
    event.mods = modifiers(mods);
    event.context = context;
    return event;
}

pub fn textEvent(codepoint: u32, storage: *[4]u8) !abi.InputEvent {
    const cp = std.math.cast(u21, codepoint) orelse return error.InvalidCodepoint;
    const len = std.unicode.utf8Encode(cp, storage) catch return error.InvalidCodepoint;
    var event = base(.text);
    event.text = .{ .ptr = storage, .len = len };
    return event;
}

pub fn focusEvent(focused: c_int) abi.InputEvent {
    var event = base(.focus);
    event.x = if (focused == 0) 0 else 1;
    return event;
}

pub const Bridge = struct {
    api: abi.ShellApi,
    edits_allowed: bool = true,
    x: i32 = 0,
    y: i32 = 0,
    failed: bool = false,

    pub fn flush(self: *Bridge) !void {
        if (self.failed) return error.SemanticInputRejected;
        if (self.api.input_flush(self.api.context) != abi.Status.ok) return error.SemanticInputFlushFailed;
    }

    fn submit(self: *Bridge, event: *const abi.InputEvent) void {
        if (self.failed) return;
        var serial: u64 = 0;
        var forwarded = event.*;
        forwarded.context = semanticContext(forwarded.context, self.edits_allowed);
        const status = self.api.input_push(self.api.context, &forwarded, &serial);
        if (status != abi.Status.ok or serial == 0) {
            self.failed = true;
            std.debug.print("[input] VM 拒绝语义输入: status={d}\n", .{status});
        }
    }
};

pub fn semanticContext(context: u32, edits_allowed: bool) u32 {
    return context | if (edits_allowed) @as(u32, 0) else input.Context.editing_unavailable;
}

test "stale views preserve input observations while suppressing edit intent" {
    try std.testing.expectEqual(input.Context.editing_unavailable, semanticContext(0, false));
    try std.testing.expectEqual(input.Context.text_input | input.Context.editing_unavailable, semanticContext(input.Context.text_input, false));
    try std.testing.expectEqual(input.Context.text_input, semanticContext(input.Context.text_input, true));
}

var current: ?*Bridge = null;

pub fn install(window: *zglfw.Window, bridge: *Bridge) !void {
    if (current != null) return error.InputBridgeAlreadyInstalled;
    const position = window.getCursorPos();
    bridge.x = (cursorEvent(position[0], position[1]) catch return error.InvalidPointerCoordinate).x;
    bridge.y = (cursorEvent(position[0], position[1]) catch return error.InvalidPointerCoordinate).y;
    current = bridge;
    _ = window.setCursorPosCallback(onCursor);
    _ = window.setMouseButtonCallback(onPointer);
    _ = window.setKeyCallback(onKey);
    _ = window.setCharCallback(onText);
    _ = window.setFocusCallback(onFocus);
}

pub fn uninstall() void {
    current = null;
}

fn onCursor(_: *zglfw.Window, x: f64, y: f64) callconv(.c) void {
    const self = current orelse return;
    const event = cursorEvent(x, y) catch {
        self.failed = true;
        return;
    };
    self.x = event.x;
    self.y = event.y;
    self.submit(&event);
}

fn textContext() u32 {
    return if (zgui.io.getWantTextInput()) input.Context.text_input else 0;
}

fn onPointer(_: *zglfw.Window, button: zglfw.MouseButton, action: zglfw.Action, mods: zglfw.Mods) callconv(.c) void {
    const self = current orelse return;
    var event = pointerEvent(button, action, mods, self.x, self.y);
    event.context = textContext();
    self.submit(&event);
}

fn onKey(_: *zglfw.Window, key: zglfw.Key, _: c_int, action: zglfw.Action, mods: zglfw.Mods) callconv(.c) void {
    const self = current orelse return;
    const event = keyEvent(key, action, mods, textContext());
    self.submit(&event);
}

fn onText(_: *zglfw.Window, codepoint: u32) callconv(.c) void {
    const self = current orelse return;
    var storage: [4]u8 = undefined;
    var event = textEvent(codepoint, &storage) catch {
        self.failed = true;
        return;
    };
    event.context = textContext();
    self.submit(&event);
}

fn onFocus(_: *zglfw.Window, focused: zglfw.Bool) callconv(.c) void {
    const self = current orelse return;
    const event = focusEvent(@backingInt(focused));
    self.submit(&event);
}

test "GLFW input maps to portable semantic events without native scancodes" {
    const pointer = pointerEvent(.right, .press, .{ .control = true, .alt = true }, 12, 24);
    try std.testing.expectEqual(@as(u8, @backingInt(input.Kind.pointer_down)), pointer.kind);
    try std.testing.expectEqual(@as(u16, 2), pointer.code);
    try std.testing.expectEqual(@as(u8, 6), pointer.mods);
    const key = keyEvent(.enter, .repeat, .{ .shift = true }, input.Context.text_input);
    try std.testing.expectEqual(input.Context.text_input, key.context);
    try std.testing.expectEqual(@as(u16, 257), key.code);
    try std.testing.expectEqual(@as(u8, @backingInt(input.Action.repeat)), key.action);
    try std.testing.expectEqual(@as(u16, 0), semanticKey(.unknown));
    var storage: [4]u8 = undefined;
    const text = try textEvent('你', &storage);
    try std.testing.expectEqualStrings("你", text.text.ptr.?[0..text.text.len]);
    try std.testing.expectError(error.InvalidCodepoint, textEvent(0x110000, &storage));
    const cursor = try cursorEvent(-4.5, 8.9);
    try std.testing.expectEqual(@as(i32, -4), cursor.x);
    try std.testing.expectEqual(@as(i32, 8), cursor.y);
    try std.testing.expectError(error.InvalidPointerCoordinate, cursorEvent(std.math.nan(f64), 0));
    try std.testing.expectEqual(@as(i32, 1), focusEvent(1).x);
}
