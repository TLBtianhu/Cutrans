const std = @import("std");
const nanoui = @import("nanoui");
const abi = @import("vne").abi;
const input = @import("vne").input;

pub fn modifiers(shift: bool, ctrl: bool, alt: bool, super: bool) u8 {
    return @as(u8, @intFromBool(shift)) |
        (@as(u8, @intFromBool(ctrl)) << 1) |
        (@as(u8, @intFromBool(alt)) << 2) |
        (@as(u8, @intFromBool(super)) << 3);
}

const NanoKey = @typeInfo(@TypeOf(@as(nanoui.ui.Context, undefined).input.key)).optional.child;

pub fn keyCode(key: NanoKey) u16 {
    return switch (key) {
        .escape => 256,
        .enter => 257,
        .tab => 258,
        .backspace => 259,
        .delete => 261,
        .right => 262,
        .left => 263,
        .down => 264,
        .up => 265,
        .page_up => 266,
        .page_down => 267,
        .home => 268,
        .end => 269,
        .f1 => 290,
        .f2 => 291,
        .f3 => 292,
        .f4 => 293,
        .f5 => 294,
        .f6 => 295,
        .f7 => 296,
        .f8 => 297,
        .f9 => 298,
        .f10 => 299,
        .f11 => 300,
        .f12 => 301,
    };
}

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

pub const Bridge = struct {
    api: abi.ShellApi,
    edits_allowed: bool = true,
    x: i32 = std.math.minInt(i32),
    y: i32 = std.math.minInt(i32),
    focused: bool = true,
    failed: bool = false,

    fn semanticContext(self: *const Bridge, c: *const nanoui.ui.Context) u32 {
        return (if (c.focused_text != null) input.Context.text_input else 0) |
            (if (self.edits_allowed) 0 else input.Context.editing_unavailable);
    }

    fn submit(self: *Bridge, c: *const nanoui.ui.Context, event: *const abi.InputEvent) void {
        if (self.failed) return;
        var forwarded = event.*;
        forwarded.context = self.semanticContext(c);
        var serial: u64 = 0;
        const status = self.api.input_push(self.api.context, &forwarded, &serial);
        if (status != abi.Status.ok or serial == 0) {
            self.failed = true;
            std.debug.print("[nanoui-input] VM rejected semantic input: status={d}\n", .{status});
        }
    }

    fn coordinate(value: f32) !i32 {
        if (!std.math.isFinite(value) or value < -2147483648.0 or value >= 2147483648.0) return error.InvalidPointerCoordinate;
        return @intFromFloat(value);
    }

    fn pointer(self: *Bridge, c: *const nanoui.ui.Context) !void {
        const x = try coordinate(c.input.mouse.x);
        const y = try coordinate(c.input.mouse.y);
        if (x != self.x or y != self.y) {
            self.x = x;
            self.y = y;
            var event = base(.pointer_move);
            event.x = x;
            event.y = y;
            self.submit(c, &event);
        }
        if (!c.input.pressed and !c.input.released and !c.input.secondary) return;
        var event = base(if (c.input.released) .pointer_up else .pointer_down);
        event.action = @backingInt(if (c.input.released) input.Action.release else input.Action.press);
        event.code = switch (c.input.button) {
            .left => 1,
            .right => 2,
            .middle => 3,
        };
        event.mods = modifiers(c.input.shift, c.input.ctrl, c.input.alt, c.input.cmd);
        event.x = x;
        event.y = y;
        self.submit(c, &event);
    }

    fn keys(self: *Bridge, c: *const nanoui.ui.Context) void {
        if (c.input.key) |key| {
            var event = base(.key_down);
            event.action = @backingInt(input.Action.press);
            event.code = keyCode(key);
            event.mods = modifiers(c.input.shift, c.input.ctrl, c.input.alt, c.input.cmd);
            self.submit(c, &event);
        }
        if (c.input.shortcut) |shortcut| {
            if (shortcut.key <= std.math.maxInt(u16)) {
                var event = base(.key_down);
                event.action = @backingInt(input.Action.press);
                event.code = @intCast(shortcut.key);
                event.mods = modifiers(shortcut.shift, shortcut.ctrl or c.input.ctrl, shortcut.alt or c.input.alt, c.input.cmd);
                self.submit(c, &event);
            }
        }
    }

    fn text(self: *Bridge, c: *const nanoui.ui.Context) void {
        if (c.input.chars.len > 0) {
            var rest = c.input.chars;
            while (rest.len > 0) {
                const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch {
                    self.failed = true;
                    return;
                };
                if (len > rest.len) {
                    self.failed = true;
                    return;
                }
                var event = base(.text);
                event.text = .{ .ptr = rest.ptr, .len = len };
                self.submit(c, &event);
                rest = rest[len..];
            }
            return;
        }
        for (c.input.ops) |op| switch (op) {
            .insert => |bytes| {
                var rest = bytes;
                while (rest.len > 0) {
                    const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch {
                        self.failed = true;
                        return;
                    };
                    if (len > rest.len) {
                        self.failed = true;
                        return;
                    }
                    var event = base(.text);
                    event.text = .{ .ptr = rest.ptr, .len = len };
                    self.submit(c, &event);
                    rest = rest[len..];
                }
            },
            else => {},
        };
    }

    pub fn flush(self: *Bridge, c: *const nanoui.ui.Context) !void {
        if (self.failed) return error.SemanticInputRejected;
        try self.pointer(c);
        self.keys(c);
        self.text(c);
        if (c.window_focused != self.focused) {
            self.focused = c.window_focused;
            var event = base(.focus);
            event.x = @intFromBool(self.focused);
            self.submit(c, &event);
        }
        if (self.failed) return error.SemanticInputRejected;
        if (self.api.input_flush(self.api.context) != abi.Status.ok) return error.SemanticInputFlushFailed;
    }
};

test "NanoUI input maps portable modifiers and special keys" {
    try std.testing.expectEqual(@as(u8, 15), modifiers(true, true, true, true));
    try std.testing.expectEqual(@as(u16, 257), keyCode(.enter));
    try std.testing.expectEqual(@as(u16, 290), keyCode(.f1));
    try std.testing.expectEqual(@as(u16, 301), keyCode(.f12));
    try std.testing.expectEqual(@as(u8, @backingInt(input.Kind.pointer_move)), base(.pointer_move).kind);
}
