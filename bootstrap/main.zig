//! main.zig — Cutrans 唯一入口：选择并校验 Runtime 与 App 载荷，在同一进程内
//! 运行虚拟环境。
//!
//! 2026-11-12 起没有独立 Host 进程，也没有 Shell 附着：桌面、资源库与无窗口
//! `exec` 都是同一个环境实例的不同前端。数据根由 `session/instance.lock`
//! 保证单写者。
const std = @import("std");
const vne = @import("vne");
const abi = vne.abi;
const launch = vne.launch;
const runtime_pack = vne.runtime_pack;
const environment = vne.environment;
const payload_source = vne.payload;
const lifecycle = vne.lifecycle;
const Control = vne.environment_control.Control;
const payload_embed = @import("payload_embed.zig");
const payload_blob = @import("payload_blob");
const runtime_provider = @import("runtime_provider");
const instance = @import("instance.zig");
const lock_port = @import("ports").instance_lock;

/// A front end that runs inside the environment until its window closes.
pub const AppRun = *const fn (std.process.Init, *const abi.ShellConfig, *const abi.ShellApi, *Control) anyerror!void;

/// Front ends linked into this executable. Headless builds pass none.
pub const Apps = struct {
    desktop: ?AppRun = null,
    library: ?AppRun = null,
};

pub const AppFlavor = enum { desktop, nanoui_library };

const Options = struct {
    launch: launch.LaunchOptions = .{},
    runtime_dir: ?[]const u8 = null,
    builtin_runtime: bool = false,
    data_dir: ?[]const u8 = null,
    shell_dir: ?[]const u8 = null,
    replay_path: ?[]const u8 = null,
    record_input: ?[]const u8 = null,
    script_path: ?[]const u8 = null,
    playback_frames: i64 = 0,
    diagnose: bool = false,
    headless: bool = false,
    assets_demo: bool = false,
    files_demo: bool = false,
    exit_demo: bool = false,
    context: ?environment.Context = null,
};

fn parseArgs(args: *std.process.Args.Iterator) !Options {
    var options: Options = .{};
    while (args.next()) |arg| {
        if (try launch.parseLaunchArg(&options.launch, args, arg)) continue;
        if (std.mem.startsWith(u8, arg, "--runtime=")) {
            if (options.runtime_dir != null or options.builtin_runtime) return error.DuplicateRuntimeDirectory;
            const selected = arg["--runtime=".len..];
            if (std.mem.eql(u8, selected, "builtin")) {
                options.builtin_runtime = true;
            } else {
                options.runtime_dir = selected;
            }
        } else if (std.mem.startsWith(u8, arg, "--data=")) {
            if (options.data_dir != null) return error.DuplicateDataDirectory;
            options.data_dir = arg["--data=".len..];
        } else if (std.mem.startsWith(u8, arg, "--shell-dir=")) {
            if (options.shell_dir != null) return error.DuplicateShellDirectory;
            options.shell_dir = arg["--shell-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--replay=")) {
            if (options.replay_path != null) return error.DuplicateReplay;
            options.replay_path = arg["--replay=".len..];
        } else if (std.mem.startsWith(u8, arg, "--record-input=")) {
            if (options.record_input != null) return error.DuplicateInputRecording;
            options.record_input = arg["--record-input=".len..];
            if (options.record_input.?.len == 0) return error.MissingInputRecordingPath;
        } else if (std.mem.startsWith(u8, arg, "--script=")) {
            if (options.script_path != null) return error.DuplicateScript;
            options.script_path = arg["--script=".len..];
        } else if (std.mem.startsWith(u8, arg, "--playback=")) {
            if (options.playback_frames != 0) return error.DuplicatePlayback;
            options.playback_frames = std.fmt.parseInt(i64, arg["--playback=".len..], 10) catch return error.InvalidPlaybackCount;
            if (options.playback_frames < 1 or options.playback_frames > 600) return error.InvalidPlaybackCount;
        } else if (std.mem.eql(u8, arg, "--diag")) {
            if (options.diagnose) return error.DuplicateDiagnostic;
            options.diagnose = true;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            if (options.headless) return error.DuplicateHeadless;
            options.headless = true;
        } else if (std.mem.eql(u8, arg, "--assets-demo")) {
            if (options.assets_demo) return error.DuplicateAssetsDemo;
            options.assets_demo = true;
        } else if (std.mem.eql(u8, arg, "--files-demo")) {
            if (options.files_demo) return error.DuplicateFilesDemo;
            options.files_demo = true;
        } else if (std.mem.eql(u8, arg, "--exit-demo")) {
            if (options.exit_demo) return error.DuplicateExitDemo;
            options.exit_demo = true;
        } else return error.InvalidArgument;
    }
    if (options.diagnose and options.headless) return error.ConflictingActions;
    if (options.playback_frames != 0 and (options.replay_path != null or options.diagnose or options.headless)) return error.ConflictingActions;
    if (options.record_input != null and (options.replay_path != null or options.diagnose or options.headless)) return error.ConflictingActions;
    if (options.assets_demo and options.files_demo) return error.ConflictingActions;
    if ((options.assets_demo or options.files_demo) and (options.playback_frames != 0 or options.replay_path != null or options.record_input != null or options.diagnose or options.headless)) return error.ConflictingActions;
    if (options.exit_demo and (options.assets_demo or options.files_demo or options.playback_frames != 0 or options.replay_path != null or options.record_input != null or options.diagnose or options.headless)) return error.ConflictingActions;
    if (options.script_path != null and (options.replay_path != null or options.diagnose or options.headless or options.playback_frames != 0 or options.record_input != null or options.assets_demo or options.files_demo or options.exit_demo or options.launch.open_path != null)) return error.ConflictingActions;
    if (options.replay_path != null and options.shell_dir != null) return error.UnexpectedShellDirectory;
    if (options.replay_path != null and (options.diagnose or options.headless)) return error.ConflictingActions;
    if (options.headless and options.launch.open_path == null and !options.diagnose and options.replay_path == null) return error.MissingAction;
    if ((options.diagnose or options.headless) and options.shell_dir != null) return error.UnexpectedShellDirectory;
    if (options.data_dir) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.DataDirectoryMustBeAbsolute;
    }
    if (options.runtime_dir) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.RuntimeDirectoryMustBeAbsolute;
    }
    if (options.shell_dir) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.ShellDirectoryMustBeAbsolute;
    }
    if (options.script_path) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.ScriptPathMustBeAbsolute;
    }
    if (options.launch.open_path) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.OpenPathMustBeAbsolute;
    }
    return options;
}

fn resolveOptions(init: std.process.Init, args: *std.process.Args.Iterator) !Options {
    var options = try parseArgs(args);
    const exe_dir = try std.process.executableDirPathAlloc(init.io, init.arena.allocator());
    const context = try environment.load(init.arena.allocator(), init.io, exe_dir);
    options.launch.mode = try context.validateMode(if (options.launch.mode_seen) options.launch.mode else null);
    if (options.launch.purpose_seen and options.launch.purpose == .normal and (options.diagnose or options.replay_path != null or options.assets_demo or options.files_demo or options.exit_demo)) return error.ConflictingRunPurpose;
    if (!options.launch.purpose_seen) {
        if (options.diagnose) options.launch.purpose = .diagnostic;
        if (options.replay_path != null) options.launch.purpose = .replay;
        if (options.assets_demo or options.files_demo or options.exit_demo) options.launch.purpose = .verification;
    }
    if (options.builtin_runtime and !runtime_provider.static_default) return error.StaticRuntimeUnavailable;
    options.context = context;
    return options;
}

fn dataDirectory(init: std.process.Init, options: Options) ![]u8 {
    const data_dir = try options.context.?.dataDir(init.io, options.data_dir, options.launch.purpose);
    try options.context.?.checkInstance(init.io, data_dir, options.launch.purpose, false);
    return data_dir;
}

// Resource validation must finish before the first persistent instance write.
fn claimDataDirectory(init: std.process.Init, options: Options, data_dir: []const u8) !void {
    try options.context.?.requireWritableData(init.io, options.data_dir, options.launch.purpose);
    try options.context.?.checkInstance(init.io, data_dir, options.launch.purpose, true);
}

fn selectedResource(init: std.process.Init, path: []const u8, data_dir: []const u8) ![]u8 {
    const allocator = init.arena.allocator();
    const canonical = try environment.canonicalPath(allocator, init.io, path);
    try environment.ensureSeparate(allocator, init.io, canonical, data_dir);
    return canonical;
}

fn manifestExists(allocator: std.mem.Allocator, io: std.Io, root: []const u8, manifest_path: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ root, manifest_path });
    defer allocator.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    return true;
}

fn defaultRuntimeDir(allocator: std.mem.Allocator, io: std.Io, context: environment.Context) ![]u8 {
    const relative = switch (context.form) {
        .development => "vm-runtime",
        .portable => "runtime",
        .installed => "runtime-envs/default",
    };
    const path = try std.fs.path.join(allocator, &.{ context.product_root, relative });
    if (!try manifestExists(allocator, io, path, runtime_pack.manifest_path)) return error.RuntimePackNotFound;
    return environment.canonicalPath(allocator, io, path);
}

fn embeddedPayloadCacheRoot(allocator: std.mem.Allocator) ![]u8 {
    const temp = std.c.getenv("TEMP") orelse std.c.getenv("TMP") orelse return error.TempDirectoryUnavailable;
    return std.fs.path.join(allocator, &.{ std.mem.span(temp), "cutrans-embedded-payload" });
}

/// The builtin App payload: `payload/<flavor>` beside the executable, or the
/// copy embedded in it when that directory is absent.
fn defaultPayloadDir(allocator: std.mem.Allocator, io: std.Io, context: environment.Context, flavor: AppFlavor) ![]u8 {
    if (!runtime_provider.static_default) return error.AppPayloadUnavailable;
    var path = try std.fs.path.join(allocator, &.{ context.product_root, if (flavor == .desktop) "payload/desktop" else "payload/nanoui-library" });
    if (!try manifestExists(allocator, io, path, payload_source.manifest_path)) {
        allocator.free(path);
        path = try payload_embed.materialize(
            allocator,
            io,
            payload_blob.id,
            payload_blob.bytes,
            try embeddedPayloadCacheRoot(allocator),
            if (flavor == .desktop) "desktop" else "nanoui-library",
        );
    }
    if (!try manifestExists(allocator, io, path, payload_source.manifest_path)) return error.PayloadNotFound;
    return environment.canonicalPath(allocator, io, path);
}

fn useStaticRuntime(options: Options) bool {
    return options.builtin_runtime or (options.runtime_dir == null and runtime_provider.static_default);
}

fn payloadDir(init: std.process.Init, options: Options, data_dir: []const u8, flavor: AppFlavor) ![]u8 {
    const candidate = if (options.shell_dir) |path| path else try defaultPayloadDir(init.arena.allocator(), init.io, options.context.?, flavor);
    return selectedResource(init, candidate, data_dir);
}

/// The static Runtime reads its resources from the desktop payload; a dynamic
/// Runtime Pack carries its own.
fn runtimeResourceDir(init: std.process.Init, options: Options, data_dir: []const u8) ![]u8 {
    if (useStaticRuntime(options)) return payloadDir(init, options, data_dir, .desktop);
    const candidate = if (options.runtime_dir) |path| path else try defaultRuntimeDir(init.arena.allocator(), init.io, options.context.?);
    return selectedResource(init, candidate, data_dir);
}

const activation = @import("activation");
const Api = activation.Api;
const slice = activation.slice;
const packIdentity = activation.packIdentity;
const create = activation.create;
const command = activation.command;
const handshake = activation.handshake;
const fingerprint = activation.fingerprint;

fn runtimeConfig(options: Options, runtime_dir: []const u8, data_dir: []const u8) abi.Config {
    return .{
        .struct_size = @sizeOf(abi.Config),
        .abi_version = abi.version,
        .mode = abi.modeToInt(options.launch.mode),
        .resource_dir = slice(runtime_dir),
        .data_dir = slice(data_dir),
    };
}

/// Exclusive use of the data root for one-shot headless work that is not an
/// environment instance (diagnostics, replay, activation).
const DataGuard = struct {
    lock: lock_port.Lock,
    legacy: lock_port.Lock,

    fn acquire(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !DataGuard {
        var lock = try lock_port.acquire(allocator, io, data_dir, lifecycle.lock_path);
        errdefer lock.deinit();
        return .{ .lock = lock, .legacy = try lock_port.acquire(allocator, io, data_dir, lifecycle.legacy_lock_path) };
    }

    fn deinit(self: *DataGuard) void {
        self.legacy.deinit();
        self.lock.deinit();
    }
};

fn openExternal(api: *const Api, handle: ?*anyopaque, path: []const u8) !void {
    var grant_id: u64 = 0;
    if (api.grant_external(handle, slice(path), 0, &grant_id) != abi.Status.ok) return error.ExternalGrantFailed;
    var uri_buffer: [64]u8 = undefined;
    try command(api, handle, "doc.open", try std.fmt.bufPrint(&uri_buffer, "external://{d}", .{grant_id}));
}

fn runSession(api: *const Api, config: *const abi.Config, options: Options, manifest: runtime_pack.Manifest) !u64 {
    const handle = try create(api, config);
    defer api.destroy(handle);
    try handshake(api, handle, manifest);
    if (options.launch.open_path) |path| {
        try openExternal(api, handle, path);
    } else {
        try command(api, handle, "doc.open", null);
    }
    if (options.diagnose and options.launch.open_path == null) {
        try command(api, handle, "editor.gain.set", "c1 0.25");
        try command(api, handle, "history.undo", null);
        try command(api, handle, "history.redo", null);
    }
    // Headless diagnostics may read an original, but only save their Session copy.
    try command(api, handle, "doc.save", null);
    return fingerprint(api, handle);
}

fn restoreSession(api: *const Api, config: *const abi.Config, manifest: runtime_pack.Manifest) !u64 {
    const handle = try create(api, config);
    defer api.destroy(handle);
    try handshake(api, handle, manifest);
    return fingerprint(api, handle);
}

/// Diagnostics and replay: a Runtime without any front end.
fn runHeadless(init: std.process.Init, options: Options) !void {
    const allocator = init.arena.allocator();
    const data_dir = try dataDirectory(init, options);
    try options.context.?.requireWritableData(init.io, options.data_dir, options.launch.purpose);
    const runtime_dir = try runtimeResourceDir(init, options, data_dir);
    var runtime = try runtime_provider.prepare(allocator, init.io, runtime_dir, data_dir, options.runtime_dir != null or options.builtin_runtime, useStaticRuntime(options));
    defer runtime.deinit();
    try claimDataDirectory(init, options, data_dir);
    // After the claim: the lock file is the first write inside the data root.
    var guard = try DataGuard.acquire(allocator, init.io, data_dir);
    defer guard.deinit();
    const api = &runtime.api;
    const manifest = runtime.descriptor();
    const config = runtimeConfig(options, runtime_dir, data_dir);
    if (options.replay_path) |path| {
        const handle = try create(api, &config);
        defer api.destroy(handle);
        try handshake(api, handle, manifest);
        var report: abi.ReplayReport = undefined;
        if (api.replay(handle, slice(path), &report) != abi.Status.ok) return error.ReplayFailed;
        try runtime.commit();
        std.debug.print("CUTRANS_REPLAY_OK kind={d} events={d} input_events={d} fingerprint={d} tasks={d} history={d} time_ns={d} tasks_hash={d} history_cursor={d}\n", .{
            report.kind,
            report.event_count,
            report.input_events,
            report.document_fingerprint,
            report.task_count,
            report.history_count,
            report.time_ns,
            report.tasks_hash,
            report.history_cursor,
        });
        return;
    }
    const saved = try runSession(api, &config, options, manifest);
    const restored = try restoreSession(api, &config, manifest);
    if (saved != restored) return error.RuntimeRestoreMismatch;
    try runtime.commit();
    std.debug.print("CUTRANS_RUNTIME_OK abi={s} capabilities={d} files={d} provider={s} mode={s} fingerprint={d}\n", .{
        manifest.abi,
        manifest.required_capabilities.len,
        manifest.files.len,
        if (useStaticRuntime(options)) "static" else "dynamic",
        @tagName(options.launch.mode),
        restored,
    });
    if (options.launch.open_path) |path| std.debug.print("CUTRANS_RUNTIME_OPEN_OK path={s}\n", .{path});
}

fn isBuiltinShell(id: []const u8) bool {
    return std.mem.eql(u8, id, "desktop-shell") or std.mem.eql(u8, id, "nanoui-library");
}

/// What the environment does once it is running.
const Front = union(enum) {
    app: struct { flavor: AppFlavor, run: AppRun },
    script: []const u8,
};

/// One environment instance: select and verify, create the Runtime, run the
/// front end, then stop normally. Every exit path persists a lifecycle state.
fn runEnvironment(init: std.process.Init, options: Options, front: Front) !void {
    const allocator = init.arena.allocator();
    const data_dir = try dataDirectory(init, options);
    try options.context.?.requireWritableData(init.io, options.data_dir, options.launch.purpose);
    const flavor: AppFlavor = switch (front) {
        .app => |app| app.flavor,
        .script => .desktop,
    };
    const runtime_dir = try runtimeResourceDir(init, options, data_dir);
    const app_dir = try payloadDir(init, options, data_dir, flavor);
    var app_resource_dir = try std.Io.Dir.openDirAbsolute(init.io, app_dir, .{});
    defer app_resource_dir.close(init.io);
    var selected_payload = try payload_source.verifyCandidate(allocator, init.io, app_resource_dir, options.shell_dir != null);
    defer selected_payload.deinit();
    const selected_app = try packIdentity(allocator, init.io, app_dir, selected_payload.manifest_path, selected_payload.manifest.value);

    var lock = try vne.runtime_lock.load(allocator, init.io, data_dir);
    defer if (lock) |*value| value.deinit();
    var allow_migration = options.shell_dir != null;
    if (lock) |owned| {
        if (owned.selection.shell) |locked_shell| {
            if (!vne.runtime_lock.identityEqual(locked_shell, selected_app)) {
                // Selecting the other built-in App (desktop <-> library) is a
                // deliberate switch. Replacing a payload while keeping the
                // same id is not: the manifest hash must match unless the user
                // explicitly passed --shell-dir.
                const sibling_switch = isBuiltinShell(locked_shell.id) and
                    isBuiltinShell(selected_app.id) and
                    !std.mem.eql(u8, locked_shell.id, selected_app.id);
                if (!allow_migration and !sibling_switch) return error.ShellLockMismatch;
                allow_migration = true;
            }
        }
    }

    var runtime = try runtime_provider.prepare(allocator, init.io, runtime_dir, data_dir, options.runtime_dir != null or options.builtin_runtime, useStaticRuntime(options));
    defer runtime.deinit();
    try claimDataDirectory(init, options, data_dir);
    var env: instance.Environment = .{
        .allocator = allocator,
        .api = &runtime.api,
        .handle = null,
        .lifecycle = try instance.Lifecycle.init(init.gpa, init.io, data_dir, options.launch.mode),
    };
    const api = &runtime.api;
    const config = runtimeConfig(options, runtime_dir, data_dir);
    env.handle = create(api, &config) catch |err| {
        env.lifecycle.deinit();
        return err;
    };
    // Declared before env.deinit's defer so the driver joins first.
    defer api.destroy(env.handle);
    defer env.deinit();
    try handshake(api, env.handle, runtime.descriptor());
    _ = try fingerprint(api, env.handle);
    try runtime.commit();
    try runtime.checkShell(selected_app, allow_migration);
    std.debug.print("CUTRANS_SHELL_PRECHECK_OK id={s}\n", .{selected_app.id});
    env.selection = .{ .runtime = &runtime, .identity = selected_app, .allow_migration = allow_migration };
    if (!options.files_demo) if (options.launch.open_path) |path| try openExternal(api, env.handle, path);
    var recording = false;
    if (options.record_input) |path| {
        if (api.input_begin(env.handle, slice(path)) != abi.Status.ok) return error.InputRecordStartFailed;
        recording = true;
    }
    defer if (recording) {
        var report: abi.InputRecordReport = undefined;
        if (api.input_end(env.handle, &report) == abi.Status.ok) {
            if (report.event_count > 0) std.debug.print("CUTRANS_INPUT_RECORD_OK events={d} time_ns={d}\n", .{ report.event_count, report.time_ns });
        } else std.debug.print("CUTRANS_INPUT_END_FAIL\n", .{});
    };
    try env.start(init.io);
    std.debug.print("CUTRANS_ENVIRONMENT_READY boot_id={d} abnormal_previous={d} mode={s}\n", .{ env.lifecycle.current.boot_id, @intFromBool(env.lifecycle.current.last_shutdown_abnormal), @tagName(options.launch.mode) });

    const shell_api = try api.shell_api(api, env.handle);
    // A failing front end does not make the environment unhealthy: it still
    // stops normally below, and the front end's error is returned afterwards.
    const front_result: anyerror!void = switch (front) {
        .app => |app| blk: {
            const shell_config = abi.ShellConfig{
                .struct_size = @sizeOf(abi.ShellConfig),
                .abi_version = abi.version,
                .mode = abi.modeToInt(options.launch.mode),
                .resource_dir = slice(app_dir),
                .data_dir = slice(data_dir),
                .open_path = if (options.launch.open_path) |path| slice(path) else .{},
                .playback_frames = options.playback_frames,
                .asset_workspace = if (options.exit_demo) 3 else if (options.files_demo) 2 else @intFromBool(options.assets_demo),
            };
            break :blk app.run(init, &shell_config, &shell_api, &env.control);
        },
        .script => |path| @import("exec.zig").run(init.gpa, init.io, path, &shell_api, &env.control),
    };
    if (front_result) |_| {} else |err| std.debug.print("CUTRANS_FRONT_END_FAIL {s}\n", .{@errorName(err)});
    var recording_result: anyerror!void = {};
    if (recording) {
        recording = false;
        var report: abi.InputRecordReport = undefined;
        if (api.input_end(env.handle, &report) == abi.Status.ok) {
            if (report.event_count > 0) std.debug.print("CUTRANS_INPUT_RECORD_OK events={d} time_ns={d}\n", .{ report.event_count, report.time_ns });
        } else recording_result = error.InputRecordEndFailed;
    }
    const payload_result = selected_payload.verify(allocator, init.io, app_resource_dir);
    if (env.control.stopped) {
        std.debug.print("CUTRANS_SAFE_EXIT_OK mode={s}\n", .{@tagName(options.launch.mode)});
    } else {
        env.finish();
        std.debug.print("CUTRANS_ENVIRONMENT_CLOSED mode={s} stopped={d}\n", .{ @tagName(options.launch.mode), @intFromBool(env.control.stopped) });
    }
    try front_result;
    try recording_result;
    try payload_result;
    if (!env.control.stopped) return error.EnvironmentStopFailed;
}

fn printContext(init: std.process.Init, options: Options, data_dir: []const u8) !void {
    const context = options.context.?;
    const text = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{
        .product_id = vne.product.id,
        .version = vne.product.version,
        .channel = context.channel,
        .form = context.form,
        .purpose = options.launch.purpose,
        .product_root = context.product_root,
        .resource_dir = context.executable_dir,
        .data_dir = data_dir,
        .services = .{ .updates = false, .accounts = false, .telemetry = false },
    }, .{});
    std.debug.print("CUTRANS_CONTEXT_JSON {s}\n", .{text});
}

/// The last persisted lifecycle record. Read-only; there is no live process to ask.
fn printStatus(init: std.process.Init, options: Options, data_dir: []const u8) !void {
    const snapshot = try instance.readPersisted(init.arena.allocator(), init.io, data_dir, options.launch.mode);
    std.debug.print("CUTRANS_ENVIRONMENT_STATUS state={s} mode={s} boot_id={d} last_shutdown_abnormal={d} abi={d} document={d} present={d}\n", .{
        @tagName(snapshot.state),
        @tagName(snapshot.mode),
        snapshot.boot_id,
        @intFromBool(snapshot.last_shutdown_abnormal),
        snapshot.abi_version,
        snapshot.document_fingerprint,
        snapshot.present_count,
    });
}

fn activateRuntime(init: std.process.Init, options: Options, data_dir: []const u8) !void {
    try options.context.?.requireWritableData(init.io, options.data_dir, options.launch.purpose);
    const allocator = init.arena.allocator();
    const runtime_dir = try runtimeResourceDir(init, options, data_dir);
    var runtime = try runtime_provider.prepare(allocator, init.io, runtime_dir, data_dir, true, useStaticRuntime(options));
    defer runtime.deinit();
    try claimDataDirectory(init, options, data_dir);
    var guard = try DataGuard.acquire(allocator, init.io, data_dir);
    defer guard.deinit();
    const config = runtimeConfig(options, runtime_dir, data_dir);
    const handle = try create(&runtime.api, &config);
    defer runtime.api.destroy(handle);
    try handshake(&runtime.api, handle, runtime.descriptor());
    const restored = try fingerprint(&runtime.api, handle);
    try runtime.commit();
    std.debug.print("CUTRANS_RUNTIME_ACTIVATED mode={s} fingerprint={d} document_edit=0\n", .{ @tagName(options.launch.mode), restored });
}

const ConsoleAction = enum { desktop, library, exec, status, context, activate_runtime };

fn consoleAction(text: []const u8) ?ConsoleAction {
    if (std.mem.eql(u8, text, "activate-runtime")) return .activate_runtime;
    return std.meta.stringToEnum(ConsoleAction, text);
}

fn requireApp(app: ?AppRun) !AppRun {
    return app orelse error.AppUnavailableInThisExecutable;
}

fn runConsole(init: std.process.Init, apps: Apps, action: ConsoleAction, args: *std.process.Args.Iterator) !void {
    const options = try resolveOptions(init, args);
    const app_options = action == .desktop or action == .library;
    if (options.replay_path != null or options.diagnose or options.headless) return error.InvalidConsoleArguments;
    if (!app_options and (options.launch.open_path != null or options.shell_dir != null or options.playback_frames != 0 or options.record_input != null or options.assets_demo or options.files_demo or options.exit_demo)) return error.InvalidConsoleArguments;
    if (action == .library and (options.playback_frames != 0 or options.exit_demo or options.record_input != null)) return error.InvalidConsoleArguments;
    if ((action == .exec) != (options.script_path != null)) return error.InvalidConsoleArguments;
    const data_dir = try dataDirectory(init, options);
    switch (action) {
        .context => try printContext(init, options, data_dir),
        .status => try printStatus(init, options, data_dir),
        .activate_runtime => try activateRuntime(init, options, data_dir),
        .desktop => try runEnvironment(init, options, .{ .app = .{ .flavor = .desktop, .run = try requireApp(apps.desktop) } }),
        .library => try runEnvironment(init, options, .{ .app = .{ .flavor = .nanoui_library, .run = try requireApp(apps.library) } }),
        .exec => try runEnvironment(init, options, .{ .script = options.script_path.? }),
    }
}

fn run(init: std.process.Init, apps: Apps) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    if (!args.skip()) return error.MissingExecutableName;
    const options = try resolveOptions(init, &args);
    if (options.script_path != null) return error.InvalidArgument;
    if (options.replay_path != null or options.diagnose or options.headless) return runHeadless(init, options);
    return runEnvironment(init, options, .{ .app = .{ .flavor = .desktop, .run = try requireApp(apps.desktop) } });
}

pub fn main(init: std.process.Init, apps: Apps) !void {
    var probe = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer probe.deinit();
    if (!probe.skip()) return error.MissingExecutableName;
    if (probe.next()) |first| {
        if (consoleAction(first)) |action| {
            runConsole(init, apps, action, &probe) catch |err| {
                std.debug.print("CUTRANS_VM_CONTROL_FAIL {s}\n", .{@errorName(err)});
                return err;
            };
            return;
        }
    }
    run(init, apps) catch |err| {
        std.debug.print("CUTRANS_BOOTSTRAP_FAIL {s}\n", .{@errorName(err)});
        return err;
    };
}

const JobsReadMock = struct {
    fail_read: bool = false,
    after: u64 = 0,

    fn read(ptr: ?*anyopaque, after: u64, buffer: ?[*]u8, capacity: usize, out_len: ?*usize) callconv(.c) i32 {
        const self: *JobsReadMock = @ptrCast(@alignCast(ptr.?));
        self.after = after;
        const text = "{\"items\":[],\"next_after\":null}";
        if (buffer == null) {
            out_len.?.* = text.len + 8;
            return abi.Status.buffer_too_small;
        }
        if (self.fail_read or capacity < text.len) {
            out_len.?.* = capacity + 1;
            return abi.Status.buffer_too_small;
        }
        @memcpy(buffer.?[0..text.len], text);
        out_len.?.* = text.len;
        return abi.Status.ok;
    }
};

test "a job query publishes only one complete successful read" {
    var mock: JobsReadMock = .{};
    var api: activation.Api = undefined;
    api.jobs_read = JobsReadMock.read;
    const page = try instance.readJobs(std.testing.allocator, &api, &mock, 41);
    defer std.testing.allocator.free(page);
    try std.testing.expectEqualStrings("{\"items\":[],\"next_after\":null}", page);
    try std.testing.expectEqual(@as(u64, 41), mock.after);
    mock.fail_read = true;
    try std.testing.expectError(error.JobsReadFailed, instance.readJobs(std.testing.allocator, &api, &mock, 42));
}

const StopMock = struct {
    flush_status: i32 = abi.Status.failed,
    save_status: i32 = abi.Status.failed,
    saves: usize = 0,
    flushed: bool = false,
    save_before_flush: bool = false,

    fn flush(ptr: ?*anyopaque) callconv(.c) i32 {
        const self: *StopMock = @ptrCast(@alignCast(ptr.?));
        self.flushed = self.flush_status == abi.Status.ok;
        return self.flush_status;
    }

    fn save(ptr: ?*anyopaque, name: abi.ByteSlice, _: abi.ByteSlice) callconv(.c) i32 {
        const self: *StopMock = @ptrCast(@alignCast(ptr.?));
        self.saves += 1;
        self.save_before_flush = self.save_before_flush or !self.flushed;
        if (name.ptr == null or !std.mem.eql(u8, name.ptr.?[0..name.len], "doc.save")) return abi.Status.invalid_arguments;
        return self.save_status;
    }
};

test "a normal stop requires final outcome persistence before document saving" {
    var mock: StopMock = .{};
    var api: activation.Api = undefined;
    api.jobs_flush = StopMock.flush;
    api.command = StopMock.save;
    try std.testing.expectError(error.JobsFlushFailed, instance.saveForStop(&api, &mock));
    try std.testing.expectEqual(@as(usize, 0), mock.saves);
    mock.flush_status = abi.Status.ok;
    try std.testing.expectError(error.RuntimeCommandFailed, instance.saveForStop(&api, &mock));
    try std.testing.expectEqual(@as(usize, 1), mock.saves);
    mock.save_status = abi.Status.ok;
    try instance.saveForStop(&api, &mock);
    try std.testing.expectEqual(@as(usize, 2), mock.saves);
    try std.testing.expect(!mock.save_before_flush);
}

test "Host-era console actions no longer exist" {
    try std.testing.expect(consoleAction("start") == null);
    try std.testing.expect(consoleAction("restart") == null);
    try std.testing.expect(consoleAction("jobs") == null);
    try std.testing.expect(consoleAction("attach") == null);
    try std.testing.expect(consoleAction("stop") == null);
    try std.testing.expectEqual(ConsoleAction.exec, consoleAction("exec").?);
}
