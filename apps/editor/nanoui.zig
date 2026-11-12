const std = @import("std");
const nanoui = @import("nanoui");

const vm_client = @import("vm_client");
const palette = @import("palette");

const ui = nanoui.ui;

pub const State = struct {
    ctx: *vm_client.Context,
    pixels: []u8 = &.{},
    pixel_generation: u64 = 0,
    gain: ui.TextBuffer = .{},
    over_bottom: ui.TextBuffer = .{},
    over_top: ui.TextBuffer = .{},
    over_opacity: ui.TextBuffer = .{},
    resize_input: ui.TextBuffer = .{},
    resize_width: ui.TextBuffer = .{},
    resize_height: ui.TextBuffer = .{},
    export_path: ui.TextBuffer = .{},
    last_task_id: ?u64 = null,

    pub fn init(ctx: *vm_client.Context) State {
        var self: State = .{ .ctx = ctx };
        const doc = &ctx.document;
        if (doc.firstGainId()) |id| {
            for (doc.nodes[0..doc.count]) |node| {
                if (node.id != id) continue;
                var buffer: [32]u8 = undefined;
                self.gain.set(std.fmt.bufPrint(&buffer, "{d}", .{node.value}) catch "0.8");
                break;
            }
        } else self.gain.set("0.8");
        self.over_bottom.set("c0");
        self.over_opacity.set("1");
        self.resize_width.set("182");
        self.resize_height.set("138");
        if (doc.outputId()) |id| {
            var buffer: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "c{d}", .{id}) catch "c1";
            self.over_top.set(text);
            self.resize_input.set(text);
        } else {
            self.over_top.set("c1");
            self.resize_input.set("c1");
        }
        return self;
    }

    pub fn deinit(self: *State) void {
        if (self.pixels.len > 0) self.ctx.allocator.free(self.pixels);
        self.pixels = &.{};
        self.gain.deinit();
        self.over_bottom.deinit();
        self.over_top.deinit();
        self.over_opacity.deinit();
        self.resize_input.deinit();
        self.resize_width.deinit();
        self.resize_height.deinit();
        self.export_path.deinit();
    }

    fn fail(self: *State, err: anyerror) void {
        self.ctx.status.set(@errorName(err));
    }

    fn require(result: @import("vne").command.Result) !void {
        if (result.code != .ok and result.code != .accepted) return error.CommandFailed;
    }

    fn dispatch(self: *State, name: []const u8, arg: ?[]const u8) @import("vne").command.Result {
        return self.ctx.command.dispatch(.{ .name = name, .arg = arg });
    }

    pub fn insertHandle(self: *State, handle: u64) !void {
        var buffer: [32]u8 = undefined;
        const arg = try std.fmt.bufPrint(&buffer, "{d}", .{handle});
        try require(self.dispatch("editor.asset.insert", arg));
        self.ctx.status.set("素材已插入当前文档");
    }

    pub fn importExternal(self: *State, path: []const u8) !void {
        const id = try vm_client.registerExternal(self.ctx, path);
        try vm_client.syncLibrary(self.ctx);
        const item = self.ctx.library_view.findResource(id) orelse return error.LibraryMirrorMissing;
        const handle = try vm_client.ensureLibraryAsset(self.ctx, id, item.content_hash);
        try self.insertHandle(handle);
    }

    pub fn pickExternal(self: *State) !void {
        const selected = try nanoui.dialog.open(self.ctx.allocator, .{
            .title = "从本机导入到当前文档",
            .button = "导入",
            .extensions = &.{},
        });
        if (selected) |paths| {
            defer nanoui.dialog.freePaths(self.ctx.allocator, paths);
            if (paths.len > 0) try self.importExternal(paths[0]);
        }
    }

    pub fn applyGain(self: *State) !void {
        try require(self.dispatch("editor.gain.set", self.gain.text()));
    }

    pub fn addInvert(self: *State) !void {
        try require(self.dispatch("editor.invert.add", null));
    }

    pub fn addOver(self: *State) !void {
        var buffer: [384]u8 = undefined;
        const arg = try std.fmt.bufPrint(&buffer, "{s} {s} {s}", .{ self.over_bottom.text(), self.over_top.text(), self.over_opacity.text() });
        try require(self.dispatch("editor.over.add", arg));
    }

    pub fn addResize(self: *State) !void {
        var buffer: [384]u8 = undefined;
        const arg = try std.fmt.bufPrint(&buffer, "{s} {s} {s}", .{ self.resize_input.text(), self.resize_width.text(), self.resize_height.text() });
        try require(self.dispatch("editor.resize.add", arg));
    }

    pub fn undo(self: *State) !void {
        try require(self.dispatch("history.undo", null));
    }

    pub fn redo(self: *State) !void {
        try require(self.dispatch("history.redo", null));
    }

    pub fn save(self: *State) !void {
        try require(self.dispatch("doc.save", null));
    }

    pub fn openDefault(self: *State) !void {
        try require(self.dispatch("doc.open", null));
    }

    pub fn exportPng(self: *State) !void {
        const path = std.mem.trim(u8, self.export_path.text(), " \t\r\n");
        const result = self.dispatch("editor.export.png", if (path.len == 0) null else path);
        try require(result);
        self.last_task_id = result.task_id;
    }

    pub fn togglePlayback(self: *State) !void {
        if (self.ctx.playback_view.active) {
            try require(self.dispatch("playback.stop", null));
        } else {
            try require(self.dispatch("playback.start", "4"));
        }
    }

    fn convert(self: *State, frame: *const vm_client.Frame) !void {
        if (self.pixel_generation == frame.generation and self.pixels.len == frame.pixels.len) return;
        const next = try self.ctx.allocator.alloc(u8, frame.pixels.len);
        errdefer self.ctx.allocator.free(next);
        for (next, frame.pixels) |*out, value| out.* = value;
        for (0..frame.pixels.len / 4) |index| {
            const offset = index * 4;
            const r = frame.pixels[offset];
            const g = frame.pixels[offset + 1];
            const b = frame.pixels[offset + 2];
            const a = frame.pixels[offset + 3];
            next[offset] = @intCast((@as(u32, b) * a + 127) / 255);
            next[offset + 1] = @intCast((@as(u32, g) * a + 127) / 255);
            next[offset + 2] = @intCast((@as(u32, r) * a + 127) / 255);
            next[offset + 3] = a;
        }
        if (self.pixels.len > 0) self.ctx.allocator.free(self.pixels);
        self.pixels = next;
        self.pixel_generation = frame.generation;
    }

    fn drawPreview(self: *State, c: *ui.Context) void {
        if (!vm_client.mirrorsFresh()) {
            ui.text(c, "正在重新同步文档，预览暂不可用。", .{ .color = c.theme.muted });
            return;
        }
        const doc = &self.ctx.document;
        var frame = vm_client.previewFrame(self.ctx, doc.fingerprint(), self.ctx.allocator) catch |err| {
            ui.textf(c, .{ .color = c.theme.danger }, "当前文档无法取得 VM 预览：{s}", .{@errorName(err)});
            return;
        };
        defer frame.deinit(self.ctx.allocator);
        self.convert(&frame) catch |err| {
            ui.textf(c, .{ .color = c.theme.danger }, "预览像素转换失败：{s}", .{@errorName(err)});
            return;
        };
        const shown = ui.image(c, .{
            .key = c.print("editor-preview-{d}-{d}", .{ doc.fingerprint(), frame.generation }),
            .source = .{ .pixels = .{ .bgra = self.pixels, .width = frame.width, .height = frame.height } },
            .max_width = 760,
            .max_height = 390,
            .scale = 1,
            .radius = 5,
        });
        if (!shown) {
            ui.text(c, "NanoUI 无法显示该预览。", .{ .color = c.theme.danger });
            return;
        }
        if (self.ctx.playback_view.currentOffer()) |t| {
            self.ctx.devices.frame_sink.offerAt(&frame, doc.fingerprint(), t);
        } else {
            self.ctx.devices.frame_sink.offer(&frame, doc.fingerprint());
        }
    }

    fn commands(self: *State, c: *ui.Context) void {
        if (vm_client.hasPending()) {
            ui.text(c, "上次修改的结果尚未确认：可等待 Host 恢复，或核对文档后停止等待。停止等待不会撤销可能已执行的修改。", .{ .color = c.theme.danger, .size = 12 });
        } else if (vm_client.hasHistoricalUnknown()) {
            ui.text(c, "上次会话有未确认的修改，可能已执行；请核对文档。", .{ .color = c.theme.danger, .size = 12 });
        }
        ui.row(c, .{ .width = .fill, .gap = 8 });
        {
            defer ui.end(c);
            if (ui.button(c, "撤销", .{}).clicked) self.undo() catch |err| self.fail(err);
            if (ui.button(c, "重做", .{}).clicked) self.redo() catch |err| self.fail(err);
            if (ui.button(c, "保存会话", .{}).clicked) self.save() catch |err| self.fail(err);
            if (ui.button(c, if (self.ctx.playback_view.active) "停止播放" else "播放 4 帧", .{}).clicked) self.togglePlayback() catch |err| self.fail(err);
            if (vm_client.hasPending()) {
                if (ui.button(c, "停止等待未确认修改", .{ .variant = .danger }).clicked) vm_client.abandonPending(self.ctx);
            } else if (vm_client.hasHistoricalUnknown()) {
                if (ui.button(c, "已核对，清除提示", .{}).clicked) vm_client.acknowledgeHistoricalUnknown(self.ctx);
            }
        }
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        {
            defer ui.end(c);
            ui.text(c, "增益", .{});
            _ = ui.textField(c, &self.gain, .{ .width = .{ .px = 100 } });
            if (ui.button(c, "应用增益", .{ .variant = .primary }).clicked) self.applyGain() catch |err| self.fail(err);
            if (ui.button(c, "添加 invert", .{}).clicked) self.addInvert() catch |err| self.fail(err);
            if (ui.button(c, "导入 PNG…", .{}).clicked) self.pickExternal() catch |err| self.fail(err);
        }
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        {
            defer ui.end(c);
            ui.text(c, "over 底/顶/透明度", .{});
            _ = ui.textField(c, &self.over_bottom, .{ .width = .{ .px = 64 } });
            _ = ui.textField(c, &self.over_top, .{ .width = .{ .px = 64 } });
            _ = ui.textField(c, &self.over_opacity, .{ .width = .{ .px = 72 } });
            if (ui.button(c, "添加 over", .{}).clicked) self.addOver() catch |err| self.fail(err);
        }
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        {
            defer ui.end(c);
            ui.text(c, "resize 输入/宽/高", .{});
            _ = ui.textField(c, &self.resize_input, .{ .width = .{ .px = 64 } });
            _ = ui.textField(c, &self.resize_width, .{ .width = .{ .px = 72 } });
            _ = ui.textField(c, &self.resize_height, .{ .width = .{ .px = 72 } });
            if (ui.button(c, "添加 resize", .{}).clicked) self.addResize() catch |err| self.fail(err);
        }
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        {
            defer ui.end(c);
            _ = ui.textField(c, &self.export_path, .{ .placeholder = "导出目标（留空为 session exports/output.png）", .width = .fill });
            if (ui.button(c, "导出 PNG", .{ .variant = .primary }).clicked) self.exportPng() catch |err| self.fail(err);
        }
    }

    fn nodes(self: *State, c: *ui.Context) void {
        const doc = &self.ctx.document;
        ui.textf(c, .{ .color = c.theme.muted }, "{d}×{d} @ {d}fps · revision {d} · {s}", .{
            doc.width, doc.height, doc.fps, self.ctx.document_revision,
            if (doc.dirty) "未保存" else "已保存",
        });
        if (self.ctx.playback_view.frames > 0) {
            ui.textf(c, .{ .color = c.theme.muted }, "静态序列 t={d}/{d} · 欠账 {d}", .{
                self.ctx.playback_view.last_t + 1, self.ctx.playback_view.frames, self.ctx.playback_view.underflow_count,
            });
        }
        for (doc.nodes[0..doc.count]) |node| {
            switch (node.op) {
                .testsrc => ui.textf(c, .{ .mono = true }, "c{d}=testsrc{{}}", .{node.id}),
                .gain => ui.textf(c, .{ .mono = true }, "c{d}=gain{{ in:c{d},value:{d} }}", .{ node.id, node.unaryInput().?, node.value }),
                .invert => ui.textf(c, .{ .mono = true }, "c{d}=invert{{ in:c{d} }}", .{ node.id, node.unaryInput().? }),
                .over => ui.textf(c, .{ .mono = true }, "c{d}=over{{ .{{in:c{d}}}, .{{in:c{d},opacity:{d}}} }}", .{ node.id, node.aggInput(0).?, node.aggInput(1).?, node.topOpacity() }),
                .image => ui.textf(c, .{ .mono = true }, "c{d}=image{{ path:\"{s}\" }}", .{ node.id, node.asset() }),
                .resize => ui.textf(c, .{ .mono = true }, "c{d}=resize{{ in:c{d},w:{d},h:{d} }}", .{ node.id, node.unaryInput().?, node.out_w, node.out_h }),
            }
        }
    }

    pub fn view(self: *State, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(16), .gap = 12 });
        defer ui.end(c);
        ui.text(c, "编辑器", .{ .size = 22, .weight = .bold });
        ui.label(c, "真实 Document 与同步单帧 DAG；所有编辑仍由 VM 提交。");
        self.commands(c);
        ui.scroll(c, .{ .grow = 1, .width = .fill, .height = .fill, .gap = 12 });
        defer ui.end(c);
        self.drawPreview(c);
        self.nodes(c);
    }
};

test "editor preview conversion produces premultiplied BGRA" {
    var ctx: vm_client.Context = undefined;
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    var state: State = .{ .ctx = &ctx };
    defer state.deinit();
    var source = [_]u8{ 200, 100, 50, 128 };
    const frame = vm_client.Frame{ .width = 1, .height = 1, .generation = 7, .pixels = &source };
    try state.convert(&frame);
    try std.testing.expectEqualSlices(u8, &.{ 25, 50, 100, 128 }, state.pixels);
}
