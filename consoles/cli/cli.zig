//! cli.zig — CLI 操作台:二进制启动后提供虚拟终端与 .ccmd 资源加载
//!
//! 启动清单由 runtime/startup.zig 以 CCB 二进制执行;本文件不解析启动先验。
//! 只有在 console.cli.start 之后,cli.load 才会把 exe 相对路径的文本资源翻成二进制 Command。

const std = @import("std");
const zgui = @import("zgui");
const surfaces = @import("runtime").surfaces;
const RuntimeContext = @import("runtime").context.Context;
const paint = @import("uikit").paint;
const theme = @import("uikit").theme;
const workspace = @import("system_workspace");

pub fn focus(ptr: *anyopaque) void {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(ptr));
    ctx.console.focus_next = true;
}

pub fn open(ptr: *anyopaque) bool {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(ptr));
    focus(ctx);
    record(ctx, "console.cli.start");
    std.debug.print("[console] cli.start\n", .{});
    return true;
}
pub fn close(ptr: *anyopaque) void {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(ptr));
    ctx.console.focus_next = false;
    ctx.console.dragging = false;
    std.debug.print("[console] cli.close\n", .{});
}

fn utf8PrefixLen(text: []const u8, max_len: usize) usize {
    const n = @min(text.len, max_len);
    if (n == text.len) return n;
    var end = n;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return end;
}

pub fn record(ctx: *RuntimeContext, text: []const u8) void {
    const n = utf8PrefixLen(text, 96);
    var entry = ctx.console.history[ctx.console.history_count % ctx.console.history.len];
    entry.len = n;
    @memcpy(entry.text[0..n], text[0..n]);
    ctx.console.history[ctx.console.history_count % ctx.console.history.len] = entry;
    ctx.console.history_count += 1;
}

fn clearHistory(ctx: *RuntimeContext) void {
    ctx.console.history_count = 0;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn dispatchLine(ctx: *RuntimeContext, raw_line: []const u8) ?@import("runtime").command.Result {
    const line = std.mem.trim(u8, raw_line, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    const separator = std.mem.indexOfAny(u8, line, " \t");
    const name = if (separator) |at| line[0..at] else line;
    const arg = if (separator) |at| unquote(std.mem.trim(u8, line[at..], " \t")) else null;
    const result = ctx.command.dispatch(.{ .name = name, .arg = arg });
    var buf: [320]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s} -> {s}", .{ line, result.codeText() }) catch line;
    record(ctx, text);
    return result;
}

/// 加载只读资源根中的文本资源;启动清单二进制可在 cli.start 后调用本函数。
pub fn executeFile(ctx: *RuntimeContext, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !usize {
    if (std.fs.path.isAbsolute(path) or std.mem.indexOf(u8, path, "..") != null) return error.InvalidResourcePath;
    const full_path = try ctx.paths.resourcePath(allocator, path);
    defer allocator.free(full_path);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(1024 * 1024));
    defer allocator.free(text);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const result = dispatchLine(ctx, trimmed) orelse continue;
        if (result.code != .ok and result.code != .accepted) return error.CommandFailed;
        count += 1;
    }
    if (count > 0) record(ctx, path);
    std.debug.print("[cli] 已加载 {s}({d} 条命令)\n", .{ path, count });
    return count;
}

var input_buf: [256:0]u8 = std.mem.zeroes([256:0]u8);

fn clampedRect(ctx: *RuntimeContext, disp: [2]f32) surfaces.Rect {
    const area = workspace.workArea(disp);
    const old = ctx.surfaces.rectOf(.console, "cli");
    const initialized = ctx.surfaces.hasRect(.console, "cli");
    var r = old;
    if (r.w <= 0) r.w = 520;
    if (r.h <= 0) r.h = 260;
    if (area.w > 0) {
        r.w = std.math.clamp(r.w, @min(320, area.w), area.w);
    } else r.w = 0;
    if (area.h > 0) {
        r.h = std.math.clamp(r.h, @min(180, area.h), area.h);
    } else r.h = 0;
    if (!initialized) {
        r.x = area.w - r.w - 32;
        r.y = area.h - r.h - 16;
    }
    r.x = std.math.clamp(r.x, 0, @max(0, area.w - r.w));
    r.y = std.math.clamp(r.y, 0, @max(0, area.h - r.h));
    if (!initialized or r.x != old.x or r.y != old.y or r.w != old.w or r.h != old.h) {
        ctx.surfaces.setRect(.console, "cli", r);
    }
    return r;
}

fn dragTick(ctx: *RuntimeContext, r: surfaces.Rect) void {
    if (!zgui.isItemActive()) {
        ctx.console.dragging = false;
        return;
    }
    const mp = zgui.getMousePos();
    if (!ctx.console.dragging) {
        ctx.console.dragging = true;
        _ = ctx.surfaces.focus(.console, "cli");
        ctx.console.drag_pos = mp;
        ctx.console.drag_rect = r;
    }
    ctx.surfaces.setRect(.console, "cli", .{
        .x = ctx.console.drag_rect.x + mp[0] - ctx.console.drag_pos[0],
        .y = ctx.console.drag_rect.y + mp[1] - ctx.console.drag_pos[1],
        .w = r.w,
        .h = r.h,
    });
}

/// CLI 的 floating 窗口:桌面/编辑器保持活动,CLI 在独立悬浮区域显示。
pub fn draw(ptr: *anyopaque) void {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(ptr));
    const disp = zgui.io.getDisplaySize();
    const r = clampedRect(ctx, disp);
    const configure_serial = ctx.surfaces.configurationSerial(.console, "cli");
    const flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_scrollbar = true,
        .no_collapse = true,
        .no_focus_on_appearing = true,
    };
    zgui.setNextWindowPos(.{ .x = r.x, .y = r.y });
    zgui.setNextWindowSize(.{ .w = r.w, .h = r.h });
    if (ctx.console.focus_next) {
        if (ctx.surfaces.isFocused(.console, "cli")) zgui.setNextWindowFocus();
        ctx.console.focus_next = false;
    }
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = theme.r_m });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = theme.sidebar_bg });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = theme.text });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = theme.border_l });
    if (zgui.begin("##cli_dock", .{ .flags = flags })) {
        paint.softShadow(zgui.getWindowDrawList(), .{ r.x, r.y + 2 }, r.w, r.h, theme.r_m);
        const drag_w = @max(0, r.w - 100);
        zgui.setCursorPos(.{ 0, 0 });
        _ = zgui.invisibleButton("##cli:drag", .{ .w = drag_w, .h = 28 });
        dragTick(ctx, r);

        zgui.setCursorPos(.{ 12, 7 });
        paint.pushFontSize(theme.f_small);
        zgui.textColored(theme.caption, "CLI 控制台", .{});
        paint.popFontSize(theme.f_small);

        zgui.setCursorPos(.{ r.w - 88, 5 });
        if (zgui.button("清空", .{ .w = 76, .h = 26 })) clearHistory(ctx);

        zgui.setCursorPos(.{ 12, 38 });
        zgui.textColored(theme.caption, "最近命令", .{});
        const history_w = @max(0, r.w - 24);
        const history_h = @max(0, r.h - 92);
        if (history_w > 0 and history_h > 0) {
            if (zgui.beginChild("##cli:history", .{ .w = history_w, .h = history_h })) {
                if (ctx.console.history_count == 0) {
                    zgui.textColored(theme.dim, "暂无命令记录", .{});
                } else {
                    const shown = @min(ctx.console.history_count, 4);
                    const first = (ctx.console.history_count - shown) % ctx.console.history.len;
                    for (0..shown) |offset| {
                        const entry = ctx.console.history[(first + offset) % ctx.console.history.len];
                        zgui.textColored(theme.dim, "{s}", .{entry.text[0..entry.len]});
                    }
                }
            }
            zgui.endChild();
        }

        const input_w = @max(0, r.w - 24);
        if (r.h >= 48 and input_w > 0) {
            zgui.setCursorPos(.{ 12, r.h - 40 });
            zgui.pushItemWidth(input_w);
            if (zgui.inputTextWithHint("##cli_input", .{
                .hint = "command.name [arg] · 回车执行",
                .buf = &ctx.console.input_buf,
                .flags = .{ .enter_returns_true = true },
            })) {
                _ = dispatchLine(ctx, std.mem.sliceTo(&ctx.console.input_buf, 0));
                ctx.console.input_buf[0] = 0;
            }
            zgui.popItemWidth();
        }
    }
    zgui.end();
    zgui.popStyleColor(.{ .count = 3 });
    zgui.popStyleVar(.{ .count = 2 });
    _ = ctx.surfaces.ackConfiguration(.console, "cli", configure_serial);
}

test "history truncation never splits a UTF-8 codepoint" {
    const text = "你好abc";
    try std.testing.expectEqual(@as(usize, 3), utf8PrefixLen(text, 4));
    try std.testing.expectEqual(@as(usize, 0), utf8PrefixLen(text, 2));
    try std.testing.expectEqual(@as(usize, 2), utf8PrefixLen("abc", 2));
}

test "clamped rect separates default placement from dragged negative coordinates" {
    var ctx: RuntimeContext = undefined;
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    try std.testing.expect(ctx.surfaces.register(.{
        .owner_kind = .console,
        .id = "cli",
        .title = "CLI",
        .mode = .floating,
        .open = open,
        .close = close,
        .draw = draw,
    }));
    var r = clampedRect(&ctx, .{ 800, 600 });
    try std.testing.expectEqual(@as(f32, 248), r.x);
    try std.testing.expectEqual(@as(f32, 264), r.y);
    ctx.surfaces.setRect(.console, "cli", .{ .x = -20, .y = -10, .w = 520, .h = 260 });
    r = clampedRect(&ctx, .{ 800, 600 });
    try std.testing.expectEqual(@as(f32, 0), r.x);
    try std.testing.expectEqual(@as(f32, 0), r.y);
}

test "cli history records structured result codes" {
    var ctx: RuntimeContext = undefined;
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    const result = dispatchLine(&ctx, "missing.command").?;
    try std.testing.expectEqual(@import("runtime").command.Code.unknown_command, result.code);
    try std.testing.expectEqual(@as(usize, 1), ctx.console.history_count);
    const entry = ctx.console.history[0];
    try std.testing.expect(std.mem.endsWith(u8, entry.text[0..entry.len], " -> unknown_command"));
}
