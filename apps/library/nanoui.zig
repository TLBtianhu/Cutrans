const std = @import("std");
const nanoui = @import("nanoui");
const abi = @import("vne").abi;
pub const State = @import("nanoui_model.zig").State;
const library_view = @import("nanoui_view.zig");
pub const view = library_view.view;
pub const metalTheme = library_view.metalTheme;

fn requiredPath(value: abi.ByteSlice) ![]const u8 {
    if (value.len == 0 or value.ptr == null) return error.InvalidPath;
    const path = value.ptr.?[0..value.len];
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    return path;
}

fn hasVisibleContent(pixels: []const u8) bool {
    if (pixels.len < 4) return false;
    for (pixels[4..], 4..) |value, index| {
        if (value != pixels[index % 4]) return true;
    }
    return false;
}

pub fn verifyD3D(tester: *nanoui.ui.Tester, allocator: std.mem.Allocator) !void {
    if (@import("builtin").os.tag != .windows) return;
    var renderer = try nanoui.ui.d3d11.Renderer.init();
    defer renderer.deinit();
    renderer.sync(tester.text.atlas.mask(), tester.text.atlas.generation, tester.text.images.pictures(), tester.text.images.generation);
    renderer.draw(tester.instances.items, tester.ctx.textures.items, tester.size, tester.scale, tester.theme.background, null);
    const gpu = try renderer.read(allocator);
    defer gpu.deinit(allocator);
    const cpu = try tester.render(allocator);
    defer cpu.deinit(allocator);
    try std.testing.expect(gpu.width == cpu.width and gpu.height == cpu.height and gpu.bytes.len == cpu.bytes.len);
    try std.testing.expect(hasVisibleContent(gpu.bytes) and hasVisibleContent(cpu.bytes));
    var total: u64 = 0;
    for (gpu.bytes, cpu.bytes) |a, b| total += @abs(@as(i16, a) - @as(i16, b));
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(gpu.bytes.len));
    try std.testing.expect(mean <= 3.0);
    std.debug.print("CUTRANS_NANOUI_D3D_OK size={d}x{d} mean={d:.4} nonblank=1\n", .{ gpu.width, gpu.height, mean });
}

const DynamicScene = struct {
    source: nanoui.ui.Texture,

    fn view(scene: *DynamicScene, c: *nanoui.ui.Context) void {
        nanoui.ui.texture(c, .{ .width = .{ .px = 64 }, .height = .{ .px = 64 }, .radius = 6 }, scene.source, .{ 0, 0, 0.5, 0.5 }, 0.8);
    }
};

pub fn verifyDynamicD3D(allocator: std.mem.Allocator) !void {
    var bytes: [40]u8 = @splat(0);
    const colors = [_][4]u8{
        .{ 20, 40, 80, 255 },
        .{ 30, 60, 100, 255 },
        .{ 40, 80, 120, 255 },
        .{ 50, 100, 140, 255 },
    };
    for (colors, 0..) |color, index| {
        const x = index % 2;
        const y = index / 2;
        @memcpy(bytes[y * 20 + x * 4 ..][0..4], &color);
    }
    var scene: DynamicScene = .{ .source = .{ .width = 2, .height = 2, .bgra = &bytes, .stride = 20 } };
    var tester: nanoui.ui.Tester = undefined;
    try tester.init(allocator, .init(&scene, DynamicScene.view), .{ .width = 100, .height = 100, .scale = 1 });
    defer tester.deinit();
    tester.settle(0.1);
    try verifyD3D(&tester, allocator);
    std.debug.print("CUTRANS_NANOUI_DYNAMIC_OK bgra=1 stride=1 uv=1\n", .{});
}

fn verify(state: *State, config: *const abi.ShellConfig) !void {
    const resource_dir = try requiredPath(config.resource_dir);
    const path = try std.fs.path.join(state.allocator, &.{ resource_dir, "assets/examples/pngtest.png" });
    defer state.allocator.free(path);
    std.debug.print("CUTRANS_NANOUI_FIXTURE path={s}\n", .{path});
    const library_id = blk: {
        _ = try state.importExternal(path);
        break :blk state.selected_library;
    };
    if (library_id == 0 or state.preview == null) return error.PreviewMissing;

    var tester: nanoui.ui.Tester = undefined;
    try tester.init(state.allocator, .init(state, library_view.view), .{
        .width = 1180,
        .height = 760,
        .scale = 1,
        .theme = library_view.metalTheme(),
    });
    defer tester.deinit();
    try std.testing.expect(tester.hasText("虚拟资源目录"));
    try std.testing.expect(tester.hasText("pngtest.png"));
    try std.testing.expect(tester.containsText("完整预览"));
    const initial = try tester.render(state.allocator);
    defer initial.deinit(state.allocator);
    try std.testing.expect(initial.width == 1180 and initial.height == 760);

    state.new_folder_buffer.set("素材");
    try tester.clickText("新建文件夹");
    var folder_id: u64 = 0;
    for (state.catalog.items[0..state.catalog.count]) |item| {
        if (item.node_kind == .folder and std.mem.eql(u8, item.label, "素材")) folder_id = item.id;
    }
    try std.testing.expect(folder_id != 0);

    const resource_text = tester.findText("pngtest.png") orelse return error.ResourceRowMissing;
    tester.rightClick(resource_text.x + resource_text.w / 2, resource_text.y + resource_text.h / 2);
    try tester.clickText("从原文件重新载入");
    try std.testing.expect(state.catalog.findResource(library_id).?.kind.? == .reference);

    tester.rightClick(resource_text.x + resource_text.w / 2, resource_text.y + resource_text.h / 2);
    try tester.clickText("保存为库内独立副本");
    const detached = state.catalog.findResource(library_id) orelse return error.LibraryMirrorMissing;
    try std.testing.expect(detached.kind.? == .owned and detached.provenance.? == .detached);

    tester.rightClick(resource_text.x + resource_text.w / 2, resource_text.y + resource_text.h / 2);
    try tester.clickText("移动到 “素材”");
    try std.testing.expect(state.catalog.findResource(library_id).?.parent_id == folder_id);

    const detached_text = tester.findText("pngtest.png") orelse return error.ResourceRowMissing;
    tester.rightClick(detached_text.x + detached_text.w / 2, detached_text.y + detached_text.h / 2);
    try tester.clickText("重命名");
    const long_label = "主角-用于验证长名称与窄窗口重排的完整资源名称.png";
    state.rename_buffer.set(long_label);
    try tester.clickText("应用重命名");
    try std.testing.expectEqualStrings(long_label, state.catalog.findResource(library_id).?.label);
    try std.testing.expect(state.preview != null);
    try std.testing.expect(tester.containsText("主角"));
    try std.testing.expect(!tester.containsText("预览解码失败"));
    tester.resize(900, 700);
    try std.testing.expect(!tester.hasText(long_label));
    var visible_label = false;
    for (tester.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.indexOf(u8, text.str, "主角") != null) {
            visible_label = true;
            try std.testing.expect(node.rect.x >= 0 and node.rect.x + node.rect.w <= 900);
        },
        else => {},
    };
    try std.testing.expect(visible_label);

    try tester.clickText("新建工作正文");
    const text_id = state.selected_library;
    try std.testing.expect(text_id != 0 and text_id != library_id and state.work.?.editor != null);
    try state.work.?.editor.?.editor.paste("第一行\r\n第二行");
    tester.frame();
    tester.frame();
    try std.testing.expect(state.work.?.editor.?.draft_revision != 0);
    try std.testing.expectEqual(@as(u64, 1), state.work.?.editor.?.work_revision);
    try tester.clickText("保存正文");
    tester.frame();
    try std.testing.expectEqual(@as(u64, 2), state.work.?.editor.?.work_revision);
    try std.testing.expectEqual(@as(u64, 0), state.work.?.editor.?.draft_revision);
    try state.work.?.editor.?.editor.paste("关闭前需要保护的正文");
    tester.frame();
    try std.testing.expect(State.shouldClose(state, undefined));
    try std.testing.expect(state.work.?.editor.?.draft_revision != 0);
    try std.testing.expectEqual(@as(u64, 2), state.work.?.editor.?.work_revision);
    try state.selectLibrary(library_id);
    try std.testing.expect(state.preview != null and state.work.?.editor == null);
    std.debug.print("CUTRANS_NANOUI_WORK_OK create=1 multiline=1 draft=1 commit=2 close_guard=1\n", .{});

    const final = try tester.render(state.allocator);
    defer final.deinit(state.allocator);
    try std.testing.expect(final.width == 900 and final.height == 700);
    try verifyD3D(&tester, state.allocator);
    try verifyDynamicD3D(state.allocator);

    std.debug.print("CUTRANS_NANOUI_LIBRARY_OK attach=1 preview={d}x{d} refresh=1 detach=1 move=1 rename=1 folder=1 narrow=1\n", .{ state.preview.?.info.width, state.preview.?.info.height });
}

pub fn run(init: std.process.Init, config: *const abi.ShellConfig, api: *const abi.ShellApi) !void {
    if (config.struct_size < @sizeOf(abi.ShellConfig) or config.abi_version != abi.version or config.reserved != 0) return error.InvalidShellConfig;
    if (config.playback_frames != 0 or config.asset_workspace > 1) return error.InvalidShellConfig;
    var io_state = std.Io.Threaded.init(init.gpa, .{});
    defer io_state.deinit();
    var state = try State.init(init.gpa, api, io_state.io());
    defer state.deinit();
    if (config.asset_workspace == 1) return verify(&state, config);

    const app = try nanoui.App.create(init, .{ .name = "Cutrans", .kv = false });
    defer app.destroy();
    _ = try app.newWindow(.{
        .title = "Cutrans · 资源库",
        .width = 1180,
        .height = 760,
        .theme = library_view.metalTheme(),
        .should_close = .{ .ctx = &state, .func = State.shouldClose },
        .content = .{ .view = .init(&state, library_view.view) },
    });
    try app.run();
}
