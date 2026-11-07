//! editor.zig — 类 PS 编辑器应用壳(与 desktop 平级)
//!
//! 当前显示真实 Document 与同步求值出的单帧:testsrc → gain → RGBA8。
//! 只有一个当前工作帧,不包含完整流协议、导出或后台渲染。

const std = @import("std");
const zgui = @import("zgui");
const RuntimeContext = @import("runtime").context.Context;
const render = @import("runtime").render;
const paint = @import("uikit").paint;
const theme = @import("uikit").theme;

extern fn zguiRegisterUserTexture(*zgui.TextureData) void;

const EditorState = struct {
    preview: render.Preview,
    texture: zgui.TextureData,
    texture_registered: bool,
    upload_generation: u64,
    resource_dir: ?std.Io.Dir,
};

fn state(ctx: *RuntimeContext) *EditorState {
    return @ptrCast(@alignCast(ctx.editor_state.?));
}

pub fn open(ptr: *anyopaque) bool {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(ptr));
    if (ctx.editor_state == null) {
        const editor_state = ctx.allocator.create(EditorState) catch return false;
        editor_state.* = .{
            .preview = .{},
            .texture = std.mem.zeroes(zgui.TextureData),
            .texture_registered = false,
            .upload_generation = 0,
            .resource_dir = null,
        };
        ctx.editor_state = editor_state;
    }
    const editor_state = state(ctx);
    if (editor_state.resource_dir == null) {
        const io = ctx.io orelse return false;
        editor_state.resource_dir = ctx.paths.openResourceDir(io) catch return false;
    }
    std.debug.print("[app] editor.open\n", .{});
    return true;
}

pub fn close(ptr: *anyopaque) void {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(ptr));
    if (ctx.editor_state) |ptr_state| {
        const editor_state: *EditorState = @ptrCast(@alignCast(ptr_state));
        if (editor_state.texture_registered and editor_state.texture.status != .destroyed) {
            editor_state.texture.status = .want_destroy;
            editor_state.texture.unused_Frames = 1;
        }
        editor_state.preview.deinit(ctx.allocator);
        if (editor_state.resource_dir) |dir| dir.close(ctx.io.?);
        editor_state.resource_dir = null;
    }
    std.debug.print("[app] editor.close\n", .{});
}

fn textureNeedsRebuild(texture: *const zgui.TextureData, frame: *const render.Frame) bool {
    return @backingInt(texture.tex_id) != 0 and
        (texture.width != frame.width or texture.height != frame.height);
}

fn previewTexture(editor_state: *EditorState, frame: *const render.Frame) ?*zgui.TextureData {
    const texture = &editor_state.texture;
    if (texture.status == .want_destroy) return null;
    if (texture.status == .destroyed) {
        editor_state.texture_registered = false;
        editor_state.upload_generation = 0;
    }
    if (!editor_state.texture_registered) {
        texture.* = std.mem.zeroes(zgui.TextureData);
        texture.unique_id = 1;
        texture.ref_count = 1;
        texture.format = .rgba32;
        texture.status = .want_create;
        editor_state.texture_registered = true;
        zguiRegisterUserTexture(texture);
    }
    if (textureNeedsRebuild(texture, frame)) {
        texture.status = .want_destroy;
        texture.unused_Frames = 1;
        return null;
    }
    if (editor_state.upload_generation != frame.generation) {
        texture.width = @intCast(frame.width);
        texture.height = @intCast(frame.height);
        texture.bytes_per_pixel = 4;
        texture.pixels = frame.pixels.ptr;
        texture.status = if (@backingInt(texture.tex_id) == 0) .want_create else .want_updates;
        editor_state.upload_generation = frame.generation;
    }
    return texture;
}

fn textureRef(texture: *zgui.TextureData) zgui.TextureRef {
    return if (@backingInt(texture.tex_id) == 0)
        .{ .tex_data = texture, .tex_id = texture.tex_id }
    else
        .{ .tex_data = null, .tex_id = texture.tex_id };
}

fn drawText(text: [:0]const u8, x: f32, y: f32, color: [4]f32) void {
    zgui.setCursorPos(.{ x, y });
    zgui.textColored(color, "{s}", .{text});
}

pub fn draw(ptr: *anyopaque) void {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(ptr));
    const configure_serial = ctx.surfaces.configurationSerial(.app, "editor");
    const editor_state = state(ctx);
    const doc = &ctx.document;
    const disp = zgui.io.getDisplaySize();
    const flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_scrollbar = true,
        .no_collapse = true,
        .no_focus_on_appearing = true,
        .no_bring_to_front_on_focus = true,
    };
    zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
    zgui.setNextWindowSize(.{ .w = disp[0], .h = disp[1] });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = theme.bg });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = theme.text });
    if (zgui.begin("##editor_root", .{ .flags = flags })) {
        zgui.setCursorPos(.{ 24, 14 });
        paint.pushFontBold(theme.f_title);
        zgui.textColored(theme.text, "Cutrans 编辑器 · 单帧预览", .{});
        paint.popFontBold();

        var info_buf: [128]u8 = undefined;
        const playback = &ctx.playback_view;
        zgui.setCursorPos(.{ 24, 58 });
        if (zgui.button(if (playback.active) "停止##playback" else "播放##playback", .{ .w = 88, .h = 28 })) {
            const result = ctx.command.dispatch(.{ .name = if (playback.active) "playback.stop" else "playback.start", .arg = if (playback.active) null else "4" });
            if (result.code != .ok and result.code != .accepted) ctx.status.set("播放命令未执行");
        }
        const playback_text = if (playback.frames > 0)
            std.fmt.bufPrint(&info_buf, "静态序列 t={d}/{d} · 欠账 {d}", .{ playback.last_t + 1, playback.frames, playback.underflow_count }) catch return
        else
            std.fmt.bufPrint(&info_buf, "静态序列 · 未播放", .{}) catch return;
        info_buf[playback_text.len] = 0;
        drawText(info_buf[0..playback_text.len :0], 128, 62, theme.dim);

        const info = std.fmt.bufPrint(&info_buf, "{d}x{d} @ {d}fps · {s}", .{ doc.width, doc.height, doc.fps, if (doc.dirty) "未保存修改" else "已保存" }) catch return;
        info_buf[info.len] = 0;
        drawText(info_buf[0..info.len :0], 24, 100, theme.dim);

        zgui.setCursorPos(.{ 24, 132 });
        zgui.textColored(theme.dim, "同步 DAG/图片 · 文档变化才重算 · 与 CLI 共享 VM 文档", .{});
        var content_y: f32 = 164;
        const main_w = disp[0];
        if (!@import("vm_client").mirrorsFresh()) {
            drawText("正在重新同步文档，预览暂不可用", 24, content_y, theme.dim);
            content_y += 32;
        } else if (editor_state.preview.currentWithProvider(doc, ctx.allocator, @import("vm_client").sourceProvider(ctx)) catch null) |frame| {
            const max_w = @max(1, main_w - 48);
            const max_h = @max(1, disp[1] - 260);
            const scale = @min(1, @min(max_w / @as(f32, @floatFromInt(frame.width)), max_h / @as(f32, @floatFromInt(frame.height))));
            const image_w = @as(f32, @floatFromInt(frame.width)) * scale;
            const image_h = @as(f32, @floatFromInt(frame.height)) * scale;
            if (previewTexture(editor_state, frame)) |texture| {
                zgui.setCursorPos(.{ 24, content_y });
                zgui.image(textureRef(texture), .{ .w = image_w, .h = image_h });
                if (playback.currentOffer()) |t| {
                    ctx.devices.frame_sink.offerAt(frame, doc.fingerprint(), t);
                } else {
                    ctx.devices.frame_sink.offer(frame, doc.fingerprint());
                }
            } else {
                drawText("正在更新预览纹理", 24, content_y, theme.dim);
            }
            content_y += image_h + 16;
        } else {
            drawText("当前文档无法求值", 24, content_y, theme.danger);
            content_y += 32;
        }

        for (doc.nodes[0..doc.count], 0..) |node, i| {
            var line_buf: [160]u8 = undefined;
            const y = content_y + @as(f32, @floatFromInt(i)) * 34;
            switch (node.op) {
                .testsrc => {
                    const line = std.fmt.bufPrint(&line_buf, "c{d}=testsrc{{}}", .{node.id}) catch continue;
                    line_buf[line.len] = 0;
                    drawText(line_buf[0..line.len :0], 24, y, theme.text);
                },
                .gain => {
                    const line = std.fmt.bufPrint(&line_buf, "c{d}=gain{{ in:c{d},value:{d} }}", .{ node.id, node.unaryInput().?, node.value }) catch continue;
                    line_buf[line.len] = 0;
                    drawText(line_buf[0..line.len :0], 24, y, theme.text);
                },
                .invert => {
                    const line = std.fmt.bufPrint(&line_buf, "c{d}=invert{{ in:c{d} }}", .{ node.id, node.unaryInput().? }) catch continue;
                    line_buf[line.len] = 0;
                    drawText(line_buf[0..line.len :0], 24, y, theme.text);
                },
                .over => {
                    const line = std.fmt.bufPrint(&line_buf, "c{d}=over{{ .{{in:c{d}}}, .{{in:c{d},opacity:{d}}} }}", .{ node.id, node.aggInput(0).?, node.aggInput(1).?, node.topOpacity() }) catch continue;
                    line_buf[line.len] = 0;
                    drawText(line_buf[0..line.len :0], 24, y, theme.text);
                },
                .image => {
                    const line = std.fmt.bufPrint(&line_buf, "c{d}=image{{ path:\"{s}\" }}", .{ node.id, node.asset() }) catch continue;
                    line_buf[line.len] = 0;
                    drawText(line_buf[0..line.len :0], 24, y, theme.text);
                },
                .resize => {
                    const line = std.fmt.bufPrint(&line_buf, "c{d}=resize{{ in:c{d},w:{d},h:{d} }}", .{ node.id, node.unaryInput().?, node.out_w, node.out_h }) catch continue;
                    line_buf[line.len] = 0;
                    drawText(line_buf[0..line.len :0], 24, y, theme.text);
                },
            }
        }
    }
    zgui.end();
    zgui.popStyleColor(.{ .count = 2 });
    zgui.popStyleVar(.{});
    _ = ctx.surfaces.ackConfiguration(.app, "editor", configure_serial);
}

test "preview texture resize requires a deferred GPU rebuild" {
    var texture = std.mem.zeroes(zgui.TextureData);
    texture.tex_id = @fromBackingInt(1);
    texture.width = 2;
    texture.height = 1;
    var pixels: [32]u8 = undefined;
    var frame = render.Frame{ .width = 4, .height = 2, .generation = 1, .pixels = &pixels };
    try std.testing.expect(textureNeedsRebuild(&texture, &frame));
    frame.width = 2;
    frame.height = 1;
    try std.testing.expect(!textureNeedsRebuild(&texture, &frame));
    texture.tex_id = @fromBackingInt(0);
    frame.width = 1;
    try std.testing.expect(!textureNeedsRebuild(&texture, &frame));
}
