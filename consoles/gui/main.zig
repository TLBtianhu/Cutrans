//! main.zig — 桌面 Shell:VM 客户端 → startup 目录 → 桌面帧泵
//!
//! 唯一硬编码自举动作=startup.execute;桌面装载和默认项都住 startup.ccb。

const std = @import("std");
const zglfw = @import("zglfw");
const zgui = @import("zgui");
const gui_backend = @import("backend.zig");
const command = @import("runtime").command;
const cli = @import("cli");
const startup = @import("runtime").startup;
const apps = @import("runtime").apps;
const RuntimeContext = @import("runtime").context.Context;
const abi = @import("vne").abi;
const vm_client = @import("vm_client");
const editor = @import("editor");
const library = @import("library");
const desktop = @import("desktop");
const workspace = @import("system_workspace");
const session = @import("runtime").session;
const icons = @import("uikit").icons;
const paint = @import("uikit").paint;
const window_port = @import("ports").window;

fn runtimeCtx(ptr: *anyopaque) *RuntimeContext {
    return @ptrCast(@alignCast(ptr));
}

const StartupBoot = struct {
    var io: std.Io = undefined;
    var arena: std.mem.Allocator = undefined;
    var context: *RuntimeContext = undefined;
    var report: startup.Report = .{};
    var failed = false;
    fn handler(c: command.Command, _: *anyopaque) command.Result {
        const phase: startup.Phase = if (c.arg) |arg| blk: {
            if (std.mem.eql(u8, arg, "configure")) break :blk .configure;
            if (std.mem.eql(u8, arg, "session")) break :blk .session;
            if (std.mem.eql(u8, arg, "all")) break :blk .all;
            StartupBoot.context.status.set("startup.execute 阶段应为 configure/session/all");
            return .failure(.failed);
        } else .all;
        const next = startup.executePhase(io, arena, &StartupBoot.context.command, phase) catch |err| {
            failed = true;
            StartupBoot.context.status.set("启动清单执行失败");
            std.debug.print("[startup] startup.execute 失败: {s}\n", .{@errorName(err)});
            return .failure(.failed);
        };
        report.files = 1;
        report.commands += next.commands;
        failed = false;
        return .success;
    }
    fn load(c: command.Command, _: *anyopaque) command.Result {
        const path = c.arg orelse return .failure(.invalid_arguments);
        _ = cli.executeFile(StartupBoot.context, io, arena, path) catch |err| {
            failed = true;
            StartupBoot.context.status.set("CLI 资源加载失败");
            std.debug.print("[cli] 加载失败 {s}: {s}\n", .{ path, @errorName(err) });
            return .failure(.failed);
        };
        return .success;
    }
};

fn requiredPath(value: abi.ByteSlice) ![]const u8 {
    if (value.len == 0 or value.ptr == null) return error.InvalidPath;
    const path = value.ptr.?[0..value.len];
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    return path;
}

fn run(config: *const abi.ShellConfig, api: *const abi.ShellApi) !void {
    if (config.struct_size < @sizeOf(abi.ShellConfig) or config.abi_version != abi.version or config.reserved != 0) return error.InvalidShellConfig;
    if (config.playback_frames < 0 or config.playback_frames > 600 or config.asset_workspace > 1) return error.InvalidPlaybackConfig;
    const allocator = std.heap.c_allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var io_state = std.Io.Threaded.init(allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();
    try vm_client.init(api);
    defer vm_client.deinit();
    const print = std.debug.print;
    var runtime_state: RuntimeContext = undefined;
    runtime_state.init(arena);
    runtime_state.io = io;
    defer runtime_state.deinit();
    runtime_state.paths = try @import("runtime").paths.Paths.fromDirsPhysical(arena, io, try abi.modeFromInt(config.mode), try requiredPath(config.resource_dir), try requiredPath(config.data_dir));
    StartupBoot.context = &runtime_state;
    StartupBoot.io = io;
    StartupBoot.arena = arena;
    _ = apps.register(&runtime_state, .{ .id = "desktop", .title = "桌面", .icon = icons.play_line, .open = desktop.open, .close = desktop.close, .draw = desktop.draw });
    _ = apps.register(&runtime_state, .{ .id = "editor", .title = "编辑器 · 预览", .icon = icons.vidicon, .open = editor.open, .close = editor.close, .draw = editor.draw });
    _ = apps.register(&runtime_state, .{ .id = "library", .title = "资源库", .icon = icons.folder, .open = library.open, .close = library.close, .draw = library.draw });
    _ = runtime_state.surfaces.register(.{ .owner_kind = .console, .id = "cli", .title = "CLI 控制台", .icon = icons.article, .mode = .floating, .z = 10, .open = cli.open, .close = cli.close, .draw = cli.draw, .request_focus = cli.focus });

    // ── 命令注册表:统一返回执行结果,启动与 UI 共用成功/失败语义 ──
    runtime_state.command.init(arena, &runtime_state);
    runtime_state.command.register("app.open", struct {
        fn handler(c: command.Command, context_ptr: *anyopaque) command.Result {
            const runtime = runtimeCtx(context_ptr);
            const id = c.arg orelse {
                runtime.status.set("app.open 需要应用 id");
                return .failure(.failed);
            };
            if (!apps.open(runtime, id)) {
                print("[command] app.open 未注册或无法打开: {s}\n", .{id});
                runtime.status.set("应用未注册或无法打开");
                return .failure(.failed);
            }
            print("[command] app.open {s}\n", .{id});
            return .success;
        }
    }.handler);
    runtime_state.command.register("app.close", struct {
        fn handler(c: command.Command, context_ptr: *anyopaque) command.Result {
            const runtime = runtimeCtx(context_ptr);
            const id = c.arg orelse return .failure(.invalid_arguments);
            if (!apps.close(runtime, id)) {
                runtime.status.set("应用不存在、未运行或受会话保护");
                return .failure(.failed);
            }
            return .success;
        }
    }.handler);
    vm_client.register(&runtime_state) catch |err| {
        print("[vm-client] 文档镜像初始化失败: {s}\n", .{@errorName(err)});
        return error.VmClientFailed;
    };
    runtime_state.command.register("startup.execute", StartupBoot.handler);
    runtime_state.command.register("console.open", struct {
        fn handler(c: command.Command, context_ptr: *anyopaque) command.Result {
            const runtime = runtimeCtx(context_ptr);
            const id = c.arg orelse {
                runtime.status.set("console.open 需要操作台 id");
                return .failure(.failed);
            };
            if (!runtime.surfaces.open(.console, id)) {
                runtime.status.set("操作台未注册或无法打开");
                return .failure(.failed);
            }
            return .success;
        }
    }.handler);
    runtime_state.command.register("console.close", struct {
        fn handler(c: command.Command, context_ptr: *anyopaque) command.Result {
            const runtime = runtimeCtx(context_ptr);
            const id = c.arg orelse return .failure(.invalid_arguments);
            if (!runtime.surfaces.close(.console, id)) {
                runtime.status.set("操作台不存在、未运行或受保护");
                return .failure(.failed);
            }
            return .success;
        }
    }.handler);
    runtime_state.command.register("session.shell", struct {
        fn handler(c: command.Command, context_ptr: *anyopaque) command.Result {
            const runtime = runtimeCtx(context_ptr);
            const id = c.arg orelse {
                runtime.status.set("session.shell 需要应用 id");
                return .failure(.failed);
            };
            if (!runtime.session.openShell(.{ .owner_kind = .app, .id = id }, true)) {
                runtime.status.set("shell 未注册或装载失败;保留当前 shell");
                return .failure(.failed);
            }
            return .success;
        }
    }.handler);
    runtime_state.command.register("taskbar.pin", struct {
        fn handler(c: command.Command, context_ptr: *anyopaque) command.Result {
            const runtime = runtimeCtx(context_ptr);
            const text = c.arg orelse {
                runtime.status.set("taskbar.pin 需要 app:id 或 console:id");
                return .failure(.failed);
            };
            const ref = session.parseRef(text) catch {
                runtime.status.set("taskbar.pin 参数应为 app:id 或 console:id");
                return .failure(.failed);
            };
            if (!runtime.session.pin(ref)) {
                runtime.status.set("固定入口未注册或数量已满");
                return .failure(.failed);
            }
            return .success;
        }
    }.handler);
    runtime_state.command.register("surface.hide", struct {
        fn handler(c: command.Command, context_ptr: *anyopaque) command.Result {
            const runtime = runtimeCtx(context_ptr);
            const text = c.arg orelse return .failure(.invalid_arguments);
            const ref = session.parseRef(text) catch return .failure(.failed);
            const hidden = if (ref.owner_kind == .app) apps.hide(runtime, ref.id) else runtime.surfaces.hide(ref.owner_kind, ref.id);
            if (!hidden) {
                runtime.status.set("Surface 不存在或未运行");
                return .failure(.failed);
            }
            return .success;
        }
    }.handler);
    runtime_state.command.register("console.cli.start", struct {
        fn handler(_: command.Command, context_ptr: *anyopaque) command.Result {
            const runtime = runtimeCtx(context_ptr);
            return if (runtime.surfaces.open(.console, "cli")) .success else .failure(.invalid_state);
        }
    }.handler);
    runtime_state.command.register("cli.load", StartupBoot.load);
    runtime_state.command.register("cli.close", struct {
        fn handler(_: command.Command, context_ptr: *anyopaque) command.Result {
            const runtime = runtimeCtx(context_ptr);
            return if (runtime.surfaces.close(.console, "cli")) .success else .failure(.invalid_state);
        }
    }.handler);
    runtime_state.command.register("font.main", struct {
        fn handler(c: command.Command, context_ptr: *anyopaque) command.Result {
            const runtime = runtimeCtx(context_ptr);
            const name = c.arg orelse {
                runtime.status.set("font.main 需要字体资产名");
                return .failure(.failed);
            };
            runtime.config.setFontMain(name) catch {
                runtime.status.set("未知字体资产(当前仅 NotoSansSC)");
                return .failure(.failed);
            };
            return .success;
        }
    }.handler);
    runtime_state.command.register("locale.default", struct {
        fn handler(c: command.Command, context_ptr: *anyopaque) command.Result {
            const runtime = runtimeCtx(context_ptr);
            const name = c.arg orelse return .failure(.invalid_arguments);
            runtime.config.setLocale(name) catch {
                runtime.status.set("不支持的语言包(当前仅 zh-CN)");
                return .failure(.failed);
            };
            return .success;
        }
    }.handler);
    // 红标汇:查无命令 → 用户可见的状态条(不是只在控制台嘟囔)
    runtime_state.command.on_unknown = struct {
        fn report(name: []const u8, context_ptr: *anyopaque) void {
            const runtime = runtimeCtx(context_ptr);
            var b: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "未知命令(未接线): {s}", .{name}) catch return;
            runtime.status.set(s);
        }
    }.report;

    // ── 唯一自举:先 configure,再 backend,最后 session ──
    StartupBoot.report = .{};
    StartupBoot.failed = false;
    _ = runtime_state.command.dispatch(.{ .name = "startup.execute", .arg = "configure" });
    if (StartupBoot.failed) return error.StartupFailed;
    _ = try runtime_state.config.localePack();

    // ── 原生窗口与 backend 边界(zglfw;无 GL 上下文)──
    try zglfw.init();
    defer zglfw.terminate();
    zglfw.windowHint(.client_api, .no_api);
    zglfw.windowHint(.decorated, false); // 无边框:标题栏自绘(PCL 风)
    // VM 真全屏:占满主显示器,不提供原生拖动/最小化/关闭入口
    const window = try zglfw.Window.create(1120, 680, "Cutrans VM", null, null);
    if (zglfw.getPrimaryMonitor()) |mon| {
        if (mon.getVideoMode()) |vm| {
            window.setMonitor(mon, 0, 0, vm.width, vm.height, vm.refresh_rate);
        } else |_| {}
    }
    defer window.destroy();

    // 原生窗口只负责显示与输入;第三方图形生命周期全部由 backend 接管。
    const hwnd = zglfw.getWin32Window(window);
    window_port.configureNativeWindow(hwnd);
    const input_bridge = @import("input_bridge.zig");
    var semantic_input = input_bridge.Bridge{ .api = api.* };
    try input_bridge.install(window, &semantic_input);
    defer input_bridge.uninstall();
    var backend = try gui_backend.Backend.init(arena, window, &runtime_state);
    defer backend.deinit();

    // backend 就绪后才允许应用 open 回调使用字体/输入/GPU 等宿主能力。
    _ = runtime_state.command.dispatch(.{ .name = "startup.execute", .arg = "session" });
    const startup_report = StartupBoot.report;
    if (StartupBoot.failed) return error.StartupFailed;
    library.setDialogOwner(&runtime_state, hwnd);
    if (config.open_path.len != 0) {
        const result = runtime_state.command.dispatch(.{ .name = "app.open", .arg = "editor" });
        if (result.code != .ok) return error.EditorOpenFailed;
    }
    print("[vm] 自举完成:{d} 文件/{d} 命令;locale={s},font={s}\n", .{
        startup_report.files,
        startup_report.commands,
        runtime_state.config.locale,
        runtime_state.config.font_main,
    });
    print("[vm] Cutrans VM 桌面就绪({d}x{d} framebuffer)\n", .{ backend.size[0], backend.size[1] });
    runtime_state.status.set("就绪");
    if (config.playback_frames > 0) {
        var argument_buffer: [32]u8 = undefined;
        const argument = try std.fmt.bufPrint(&argument_buffer, "{d}", .{config.playback_frames});
        if (runtime_state.command.dispatch(.{ .name = "playback.start", .arg = argument }).code != .accepted) return error.PlaybackStartFailed;
    }
    if (config.asset_workspace == 1) {
        const result = runtime_state.command.dispatch(.{ .name = "app.open", .arg = "library" });
        if (result.code != .ok) return error.LibraryOpenFailed;
        try library.verifyPackExample(&runtime_state);
        const editor_result = runtime_state.command.dispatch(.{ .name = "app.open", .arg = "editor" });
        if (editor_result.code != .ok) return error.EditorOpenFailed;
    }

    // ── 帧循环(节拍泵:睡到事件,呈现即 vsync)──
    var last_frame_log_generation: u64 = 0;
    var last_frame_log_t: ?i64 = null;
    while (!window.shouldClose()) {
        semantic_input.edits_allowed = vm_client.mirrorsFresh();
        zglfw.pollEvents();
        try semantic_input.flush();
        _ = runtime_state.command.flush();
        vm_client.pump(&runtime_state) catch |err| {
            print("[task] 导出任务失败: {s}\n", .{@errorName(err)});
        };
        runtime_state.command.beginFrame();

        if (!backend.nextFrame(window)) {
            runtime_state.command.endFrame();
            if (backend.deviceLost()) return error.GpuDeviceLost;
            continue;
        }
        zgui.newFrame();

        if (zgui.isMouseClicked(.left)) {
            const area = workspace.workArea(zgui.io.getDisplaySize());
            const mouse = zgui.getMousePos();
            _ = runtime_state.surfaces.focusAt(
                .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h },
                .{ .x = mouse[0], .y = mouse[1] },
            );
        }
        paint.ime_anchor = null; // 每帧清零,激活的输入框会在绘制时重新上报
        const previous_offers = runtime_state.devices.frame_sink.offer_count;
        if (!runtime_state.surfaces.drawActive()) workspace.drawEmpty(&runtime_state);
        runtime_state.surfaces.drawDocks();
        workspace.drawTaskbar(&runtime_state);
        runtime_state.command.endFrame();
        window_port.applyImeAnchor(hwnd, if (paint.ime_anchor) |a| .{
            .x = @intFromFloat(a[0]),
            .y = @intFromFloat(a[1]),
            .w = 0,
            .h = 0,
        } else null);

        zgui.render();
        const presentation = backend.render(zgui.getDrawData());
        if (runtime_state.surfaces.isVisible(.app, "editor") and vm_client.mirrorsFresh()) {
            const sink = &runtime_state.devices.frame_sink;
            const kind: @import("vne").frame.ReportKind = if (presentation == .submitted and sink.offer_count != previous_offers) .submitted else .unavailable;
            const report = abi.FrameReport{
                .struct_size = @sizeOf(abi.FrameReport),
                .abi_version = abi.version,
                .content_id = if (kind == .submitted) sink.last_content_id else 0,
                .generation = if (kind == .submitted) sink.last_generation else 0,
                .t = sink.last_t,
                .kind = @backingInt(kind),
            };
            try vm_client.frameReport(&report);
            // Static content can keep one generation throughout playback.
            // Log only accepted GPU submissions whose generation or time changed.
            if (kind == .submitted and (report.generation != last_frame_log_generation or last_frame_log_t == null or report.t != last_frame_log_t.?)) {
                print("CUTRANS_SHELL_FRAME_OK generation={d} content={d} t={d}\n", .{ report.generation, report.content_id, report.t });
                last_frame_log_generation = report.generation;
                last_frame_log_t = report.t;
            }
        }
    }
}

pub export fn cutrans_shell_run(config: ?*const abi.ShellConfig, api: ?*const abi.ShellApi) callconv(.c) i32 {
    const value = config orelse return abi.Status.invalid_arguments;
    const shell_api = api orelse return abi.Status.invalid_arguments;
    run(value, shell_api) catch |err| {
        std.debug.print("[shell] 启动或运行失败: {s}\n", .{@errorName(err)});
        return abi.Status.failed;
    };
    return abi.Status.ok;
}
