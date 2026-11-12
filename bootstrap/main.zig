const std = @import("std");
const vne = @import("vne");
const abi = vne.abi;
const launch = vne.launch;
const runtime_pack = vne.runtime_pack;
const Library = @import("ports").library.Library;
const environment = vne.environment;
const payload_source = vne.payload;
const payload_embed = @import("payload_embed.zig");
const payload_blob = @import("payload_blob");
const host_protocol = vne.host_protocol;
const host_lifecycle = @import("host").lifecycle;
const runtime_provider = @import("runtime_provider");

const Options = struct {
    launch: launch.LaunchOptions = .{},
    runtime_dir: ?[]const u8 = null,
    builtin_runtime: bool = false,
    data_dir: ?[]const u8 = null,
    shell_dir: ?[]const u8 = null,
    replay_path: ?[]const u8 = null,
    record_input: ?[]const u8 = null,
    playback_frames: i64 = 0,
    diagnose: bool = false,
    headless: bool = false,
    assets_demo: bool = false,
    files_demo: bool = false,
    exit_demo: bool = false,
    role_seen: bool = false,
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
        } else if (std.mem.startsWith(u8, arg, "--role=")) {
            if (options.role_seen) return error.DuplicateProcessRole;
            options.role_seen = true;
            _ = try @import("roles.zig").parse(arg);
        } else return error.InvalidArgument;
    }
    if (options.diagnose and options.headless) return error.ConflictingActions;
    if (options.playback_frames != 0 and (options.replay_path != null or options.diagnose or options.headless)) return error.ConflictingActions;
    if (options.record_input != null and (options.replay_path != null or options.diagnose or options.headless)) return error.ConflictingActions;
    if (options.assets_demo and options.files_demo) return error.ConflictingActions;
    if ((options.assets_demo or options.files_demo) and (options.playback_frames != 0 or options.replay_path != null or options.record_input != null or options.diagnose or options.headless)) return error.ConflictingActions;
    if (options.exit_demo and (options.assets_demo or options.files_demo or options.playback_frames != 0 or options.replay_path != null or options.record_input != null or options.diagnose or options.headless)) return error.ConflictingActions;
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

fn selectedResource(init: std.process.Init, options: Options, path: []const u8, data_dir: []const u8) ![]u8 {
    const allocator = init.arena.allocator();
    const canonical = try environment.canonicalPath(allocator, init.io, path);
    try environment.ensureSeparate(allocator, init.io, canonical, data_dir);
    _ = options;
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

pub const AttachedShell = enum { desktop, nanoui_library };

fn embeddedPayloadCacheRoot(allocator: std.mem.Allocator) ![]u8 {
    const temp = std.c.getenv("TEMP") orelse std.c.getenv("TMP") orelse return error.TempDirectoryUnavailable;
    return std.fs.path.join(allocator, &.{ std.mem.span(temp), "cutrans-embedded-payload" });
}

fn defaultShellDir(allocator: std.mem.Allocator, io: std.Io, context: environment.Context, flavor: AttachedShell, data_dir: []const u8) ![]u8 {
    _ = data_dir;
    const relative = if (runtime_provider.static_default)
        if (flavor == .desktop) "payload/desktop" else "payload/nanoui-library"
    else switch (context.form) {
        .development => if (flavor == .desktop) "vm-shell" else "nanoui-library",
        .portable => if (flavor == .desktop) "shell" else "nanoui-library",
        .installed => if (flavor == .desktop) "shells/desktop" else "shells/nanoui-library",
    };
    var path = try std.fs.path.join(allocator, &.{ context.product_root, relative });
    if (runtime_provider.static_default) {
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
    } else {
        if (!try manifestExists(allocator, io, path, runtime_pack.shell_manifest_path)) return error.ShellPackNotFound;
    }
    return environment.canonicalPath(allocator, io, path);
}

fn useStaticRuntime(options: Options) bool {
    return options.builtin_runtime or (options.runtime_dir == null and runtime_provider.static_default);
}

fn runtimeResourceDir(init: std.process.Init, options: Options, data_dir: []const u8) ![]u8 {
    const allocator = init.arena.allocator();
    if (useStaticRuntime(options)) {
        try verifyShellCandidate(init, options, data_dir, .desktop);
        const candidate = try defaultShellDir(allocator, init.io, options.context.?, .desktop, data_dir);
        return selectedResource(init, options, candidate, data_dir);
    }
    const candidate = if (options.runtime_dir) |path| path else try defaultRuntimeDir(allocator, init.io, options.context.?);
    return selectedResource(init, options, candidate, data_dir);
}

fn verifyRuntimeCandidate(init: std.process.Init, options: Options, data_dir: []const u8) !void {
    if (useStaticRuntime(options)) {
        const runtime_dir = try runtimeResourceDir(init, options, data_dir);
        var candidate = try runtime_provider.prepare(init.arena.allocator(), init.io, runtime_dir, data_dir, options.runtime_dir != null or options.builtin_runtime, useStaticRuntime(options));
        candidate.deinit();
        return;
    }
    const runtime_dir = try runtimeResourceDir(init, options, data_dir);
    var resource_dir = try std.Io.Dir.openDirAbsolute(init.io, runtime_dir, .{});
    defer resource_dir.close(init.io);
    const parsed = try runtime_pack.verifyFile(init.arena.allocator(), init.io, resource_dir);
    defer parsed.deinit();
}

fn verifyShellCandidate(init: std.process.Init, options: Options, data_dir: []const u8, flavor: AttachedShell) !void {
    const allocator = init.arena.allocator();
    const candidate = if (options.shell_dir) |path| path else try defaultShellDir(allocator, init.io, options.context.?, flavor, data_dir);
    const shell_dir = try selectedResource(init, options, candidate, data_dir);
    var resource_dir = try std.Io.Dir.openDirAbsolute(init.io, shell_dir, .{});
    defer resource_dir.close(init.io);
    var selected = if (runtime_provider.static_default)
        try payload_source.verifyCandidate(allocator, init.io, resource_dir, options.shell_dir != null)
    else
        try payload_source.legacyCandidate(allocator, init.io, resource_dir);
    defer selected.deinit();
}

const activation = @import("activation");
const Api = activation.Api;
const slice = activation.slice;
const packIdentity = activation.packIdentity;
const create = activation.create;
const command = activation.command;
const handshake = activation.handshake;
const fingerprint = activation.fingerprint;
const presentCount = activation.presentCount;

fn shellApi(self: *const Api, context: ?*anyopaque) !abi.ShellApi {
    return self.shell_api(self, context);
}

fn runSession(api: *const Api, config: *const abi.Config, options: Options, manifest: runtime_pack.Manifest) !u64 {
    const handle = try create(api, config);
    defer api.destroy(handle);
    try handshake(api, handle, manifest);
    var uri_buffer: [64]u8 = undefined;
    const uri = if (options.launch.open_path) |path| blk: {
        var grant_id: u64 = 0;
        if (api.grant_external(handle, slice(path), 0, &grant_id) != abi.Status.ok) return error.ExternalGrantFailed;
        break :blk try std.fmt.bufPrint(&uri_buffer, "external://{d}", .{grant_id});
    } else null;
    if (uri) |path| {
        try command(api, handle, "doc.open", path);
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

fn runDesktop(init: std.process.Init, options: Options) !void {
    const data_dir = try dataDirectory(init, options);
    try verifyShellCandidate(init, options, data_dir, .desktop);
    try startConsole(init, options, data_dir);
    try attachConsole(init, options, data_dir, .desktop, false);
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    if (!args.skip()) return error.MissingExecutableName;
    const options = try resolveOptions(init, &args);
    if (options.replay_path == null and !options.diagnose and !options.headless) return runDesktop(init, options);
    const data_dir = try dataDirectory(init, options);
    try options.context.?.requireWritableData(init.io, options.data_dir, options.launch.purpose);
    const runtime_dir = try runtimeResourceDir(init, options, data_dir);
    try ensureNoRunningHost(allocator, init.io, data_dir, options.launch.mode);

    var runtime = try runtime_provider.prepare(allocator, init.io, runtime_dir, data_dir, options.runtime_dir != null or options.builtin_runtime, useStaticRuntime(options));
    defer runtime.deinit();
    try claimDataDirectory(init, options, data_dir);
    const api = &runtime.api;
    const manifest = runtime.descriptor();

    const config = abi.Config{
        .struct_size = @sizeOf(abi.Config),
        .abi_version = abi.version,
        .mode = abi.modeToInt(options.launch.mode),
        .resource_dir = slice(runtime_dir),
        .data_dir = slice(data_dir),
    };
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
    if (options.diagnose or options.headless) {
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
        return;
    }
}

fn printSnapshot(prefix: []const u8, snapshot: host_protocol.Snapshot) void {
    std.debug.print("{s} state={s} mode={s} boot_id={d} last_shutdown_abnormal={d} abi={d} document={d} present={d}\n", .{
        prefix,
        @tagName(snapshot.state),
        @tagName(snapshot.mode),
        snapshot.boot_id,
        @intFromBool(snapshot.last_shutdown_abnormal),
        snapshot.abi_version,
        snapshot.document_fingerprint,
        snapshot.present_count,
    });
}

fn validateLive(snapshot: host_protocol.Snapshot, mode: launch.Mode) !host_protocol.Snapshot {
    if (snapshot.mode != mode or snapshot.abi_version != abi.version) return error.HostAbiMismatch;
    return snapshot;
}

fn liveStatus(allocator: std.mem.Allocator, data_dir: []const u8, mode: launch.Mode) !host_protocol.Snapshot {
    const endpoint = try host_protocol.endpoint(allocator, data_dir);
    defer allocator.free(endpoint);
    return validateLive(try host_lifecycle.status(allocator, endpoint), mode);
}

fn ensureNoRunningHost(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, mode: launch.Mode) !void {
    if (liveStatus(allocator, data_dir, mode)) |current| {
        if (current.state != .stopped) return error.HostAlreadyRunning;
    } else |err| switch (err) {
        error.HostUnavailable, error.HostTimeout => {
            const persisted = try host_lifecycle.readPersisted(allocator, io, data_dir, mode);
            if (persisted.state != .stopped) return error.HostUnreachable;
        },
        else => return err,
    }
}

fn printUnreachable(snapshot: host_protocol.Snapshot) void {
    std.debug.print("CUTRANS_VM_STATUS state=unreachable last_state={s} mode={s} boot_id={d} last_shutdown_abnormal={d} abi={d} document={d} present={d}\n", .{
        @tagName(snapshot.state),
        @tagName(snapshot.mode),
        snapshot.boot_id,
        @intFromBool(snapshot.last_shutdown_abnormal),
        snapshot.abi_version,
        snapshot.document_fingerprint,
        snapshot.present_count,
    });
}

fn appendQuoted(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    if (std.mem.indexOfScalar(u8, value, '"') != null) return error.InvalidArgument;
    try out.append(allocator, '"');
    try out.appendSlice(allocator, value);
    if (std.mem.endsWith(u8, value, "\\")) try out.append(allocator, '\\');
    try out.append(allocator, '"');
}

fn appendArgument(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    try out.appendSlice(allocator, name);
    try appendQuoted(out, allocator, value);
}

fn waitHostRunning(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, mode: launch.Mode) !void {
    for (0..50) |_| {
        if (liveStatus(allocator, data_dir, mode)) |current| {
            if (current.state == .running) return;
            if (current.state == .stopped) return error.HostStartFailed;
        } else |err| switch (err) {
            error.HostUnavailable, error.HostTimeout => {},
            else => return err,
        }
        try std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake);
    }
    return error.HostStartFailed;
}

/// A replied `stopped` snapshot does not prove the old process has released its
/// single-instance lock. Wait for the control endpoint itself to disappear
/// before spawning a replacement.
fn waitHostGone(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !void {
    const endpoint = try host_protocol.endpoint(allocator, data_dir);
    defer allocator.free(endpoint);
    for (0..50) |_| {
        _ = host_lifecycle.status(allocator, endpoint) catch |err| switch (err) {
            error.HostUnavailable => return,
            error.HostTimeout => {},
            else => return err,
        };
        try std.Io.sleep(io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake);
    }
    return error.HostStopTimeout;
}

fn startConsole(init: std.process.Init, options: Options, data_dir: []const u8) !void {
    const allocator = init.arena.allocator();
    try options.context.?.requireWritableData(init.io, options.data_dir, options.launch.purpose);
    if (liveStatus(allocator, data_dir, options.launch.mode)) |current| {
        switch (current.state) {
            .running => {
                printSnapshot("CUTRANS_VM_START_OK already=1", current);
                return;
            },
            .starting => {
                try waitHostRunning(allocator, init.io, data_dir, options.launch.mode);
                const now = try liveStatus(allocator, data_dir, options.launch.mode);
                printSnapshot("CUTRANS_VM_START_OK already=1", now);
                return;
            },
            .stopping, .degraded => {
                // A previous Shell left without completing the stop, or a save
                // failure degraded the Host. Finish that stop before starting a
                // new incarnation; do not report HostNotReady and strand the user.
                try stopConsole(init, options, data_dir);
                try waitHostGone(allocator, init.io, data_dir);
            },
            .stopped => try waitHostGone(allocator, init.io, data_dir),
        }
    } else |err| switch (err) {
        error.HostUnavailable => {},
        else => return err,
    }
    // Fail in this entry point before spawning; the Host revalidates and owns
    // the first data write only after Activation.prepare has also checked ABI.
    try verifyRuntimeCandidate(init, options, data_dir);
    const exe_dir = try std.process.executableDirPathAlloc(init.io, allocator);
    const unified = try @import("roles.zig").currentIfUnified(allocator, init.io);
    defer if (unified) |path| allocator.free(path);
    const host_path = if (unified) |path| path else try std.fs.path.join(allocator, &.{ exe_dir, "cutrans_vm_host.exe" });
    var command_line: std.ArrayList(u8) = .empty;
    try appendQuoted(&command_line, allocator, host_path);
    if (unified != null) try command_line.appendSlice(allocator, " --role=host");
    try appendArgument(&command_line, allocator, " --mode=", @tagName(options.launch.mode));
    try appendArgument(&command_line, allocator, " --purpose=", @tagName(options.launch.purpose));
    try appendArgument(&command_line, allocator, " --data=", data_dir);
    if (options.runtime_dir) |path| try appendArgument(&command_line, allocator, " --runtime=", path);
    var child = try @import("ports").process.Detached.startIn(allocator, command_line.items, exe_dir);
    child.deinit();
    for (0..150) |attempt| {
        if (liveStatus(allocator, data_dir, options.launch.mode)) |current| {
            if (current.state != .running) return error.HostStartFailed;
            printSnapshot("CUTRANS_VM_START_OK already=0", current);
            return;
        } else |err| switch (err) {
            error.HostUnavailable, error.HostTimeout => {
                if (attempt % 10 == 0) std.debug.print("[vm-start] attempt={d} error={s}\n", .{ attempt, @errorName(err) });
                try std.Io.sleep(init.io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake);
            },
            else => return err,
        }
    }
    return error.HostStartTimeout;
}

fn stopConsole(init: std.process.Init, options: Options, data_dir: []const u8) !void {
    const allocator = init.arena.allocator();
    const endpoint = try host_protocol.endpoint(allocator, data_dir);
    var already_stopped = false;
    const response = host_lifecycle.stop(allocator, endpoint) catch |err| switch (err) {
        error.HostUnavailable, error.HostTimeout => blk: {
            const persisted = try host_lifecycle.readPersisted(allocator, init.io, data_dir, options.launch.mode);
            if (persisted.state != .stopped) return error.HostUnreachable;
            already_stopped = true;
            break :blk persisted;
        },
        else => return err,
    };
    const current = try validateLive(response, options.launch.mode);
    if (current.state != .stopped) {
        printSnapshot("CUTRANS_VM_STOP_FAIL", current);
        return error.HostStopFailed;
    }
    printSnapshot(if (already_stopped) "CUTRANS_VM_STOP_OK already=1" else "CUTRANS_VM_STOP_OK already=0", current);
}

fn attachConsole(init: std.process.Init, options: Options, data_dir: []const u8, flavor: AttachedShell, wait_for_completion: bool) !void {
    try options.context.?.requireWritableData(init.io, options.data_dir, options.launch.purpose);
    const allocator = init.arena.allocator();
    try verifyShellCandidate(init, options, data_dir, flavor);
    const current = try liveStatus(allocator, data_dir, options.launch.mode);
    if (current.state != .running) return error.HostNotReady;
    const exe_dir = try std.process.executableDirPathAlloc(init.io, allocator);
    const explicit_selection = options.shell_dir != null;
    const shell_source = options.shell_dir orelse try defaultShellDir(allocator, init.io, options.context.?, flavor, data_dir);
    const shell_dir = try selectedResource(init, options, shell_source, data_dir);
    const unified = try @import("roles.zig").currentIfUnified(allocator, init.io);
    defer if (unified) |path| allocator.free(path);
    const shell_path = if (unified) |path| path else switch (flavor) {
        .desktop => try std.fs.path.join(allocator, &.{ exe_dir, "cutrans_shell.exe" }),
        .nanoui_library => blk: {
            var resource_dir = try std.Io.Dir.openDirAbsolute(init.io, shell_dir, .{});
            defer resource_dir.close(init.io);
            const parsed = try runtime_pack.verifyShellFile(allocator, init.io, resource_dir);
            defer parsed.deinit();
            break :blk try std.fs.path.join(allocator, &.{ shell_dir, parsed.value.entry });
        },
    };
    var command_line: std.ArrayList(u8) = .empty;
    try appendQuoted(&command_line, allocator, shell_path);
    if (unified != null) try command_line.appendSlice(allocator, if (flavor == .desktop) " --role=shell" else " --role=library");
    try appendArgument(&command_line, allocator, " --mode=", @tagName(options.launch.mode));
    try appendArgument(&command_line, allocator, " --purpose=", @tagName(options.launch.purpose));
    try appendArgument(&command_line, allocator, " --data=", data_dir);
    if (options.launch.open_path) |path| try appendArgument(&command_line, allocator, " --open=", path);
    if (options.record_input) |path| try appendArgument(&command_line, allocator, " --record-input=", path);
    if (explicit_selection) try appendArgument(&command_line, allocator, " --shell-dir=", shell_dir);
    if (options.playback_frames != 0) {
        var argument: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&argument, "{d}", .{options.playback_frames});
        try appendArgument(&command_line, allocator, " --playback=", value);
    }
    if (options.assets_demo) try command_line.appendSlice(allocator, " --assets-demo");
    if (options.exit_demo) try command_line.appendSlice(allocator, " --exit-demo");
    var child = try @import("ports").process.Detached.startIn(allocator, command_line.items, exe_dir);
    defer child.deinit();
    if (wait_for_completion) {
        const exit_code = try child.wait();
        if (exit_code != 0) {
            std.debug.print("CUTRANS_VM_ATTACH_FAIL code={d}\n", .{exit_code});
            return error.ShellAttachFailed;
        }
        std.debug.print("CUTRANS_VM_ATTACH_OK shell={s} boot_id={d} document={d}\n", .{ @tagName(flavor), current.boot_id, current.document_fingerprint });
    } else {
        std.debug.print("CUTRANS_VM_ATTACH_ACCEPTED shell={s} boot_id={d} document={d}\n", .{ @tagName(flavor), current.boot_id, current.document_fingerprint });
    }
}

const ConsoleAction = enum { start, status, stop, restart, attach, library, desktop, activate_runtime, context, jobs };

const max_jobs_json = 256 * 1024;

fn jobsConsole(allocator: std.mem.Allocator, data_dir: []const u8, mode: launch.Mode) !void {
    const current = try liveStatus(allocator, data_dir, mode);
    if (current.state != .running and current.state != .degraded) return error.HostNotReady;
    const endpoint = try host_protocol.endpoint(allocator, data_dir);
    defer allocator.free(endpoint);
    var connection = try @import("ports").host_control.connect(allocator, endpoint);
    defer connection.deinit();
    const protocol = @import("shell_client").protocol;
    var header: [protocol.header_size]u8 = undefined;
    try connection.writeMessage(try protocol.writeRequest(&header, .{ .kind = .jobs_read }));
    const count = try connection.readMessage(&header);
    const response = try protocol.parseResponse(header[0..count], .jobs_read);
    if (response.status != abi.Status.ok or response.payload_len == 0 or response.payload_len > max_jobs_json) return error.JobsReadFailed;
    const bytes = try allocator.alloc(u8, response.payload_len);
    defer allocator.free(bytes);
    if (try connection.readMessage(bytes) != bytes.len) return error.InvalidJobsResponse;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    std.debug.print("CUTRANS_VM_JOBS_JSON {s}\n", .{bytes});
}

fn consoleAction(text: []const u8) ?ConsoleAction {
    if (std.mem.eql(u8, text, "activate-runtime")) return .activate_runtime;
    return std.meta.stringToEnum(ConsoleAction, text);
}

fn activateRuntime(init: std.process.Init, options: Options, data_dir: []const u8) !void {
    try options.context.?.requireWritableData(init.io, options.data_dir, options.launch.purpose);
    const allocator = init.arena.allocator();
    try ensureNoRunningHost(allocator, init.io, data_dir, options.launch.mode);
    const runtime_dir = try runtimeResourceDir(init, options, data_dir);
    var runtime = try runtime_provider.prepare(allocator, init.io, runtime_dir, data_dir, true, useStaticRuntime(options));
    defer runtime.deinit();
    try claimDataDirectory(init, options, data_dir);
    const config = abi.Config{
        .struct_size = @sizeOf(abi.Config),
        .abi_version = abi.version,
        .mode = abi.modeToInt(options.launch.mode),
        .resource_dir = slice(runtime_dir),
        .data_dir = slice(data_dir),
    };
    const handle = try create(&runtime.api, &config);
    defer runtime.api.destroy(handle);
    try handshake(&runtime.api, handle, runtime.descriptor());
    const restored = try fingerprint(&runtime.api, handle);
    try runtime.commit();
    std.debug.print("CUTRANS_RUNTIME_ACTIVATED mode={s} fingerprint={d} document_edit=0\n", .{ @tagName(options.launch.mode), restored });
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

fn runConsole(init: std.process.Init, action: ConsoleAction, args: *std.process.Args.Iterator) !void {
    const options = try resolveOptions(init, args);
    const attach_options = action == .attach or action == .library or action == .desktop;
    const record_options = action == .attach or action == .desktop;
    if (options.replay_path != null or (!record_options and options.record_input != null) or options.diagnose or options.headless or (!attach_options and (options.launch.open_path != null or options.shell_dir != null or options.playback_frames != 0 or options.assets_demo or options.exit_demo))) return error.InvalidConsoleArguments;
    if ((action == .attach and (options.runtime_dir != null or options.builtin_runtime)) or (action == .library and (options.playback_frames != 0 or options.exit_demo))) return error.InvalidConsoleArguments;
    const allocator = init.arena.allocator();
    const data_dir = try dataDirectory(init, options);
    switch (action) {
        .context => try printContext(init, options, data_dir),
        .jobs => try jobsConsole(allocator, data_dir, options.launch.mode),
        .activate_runtime => try activateRuntime(init, options, data_dir),
        .start => try startConsole(init, options, data_dir),
        .attach => try attachConsole(init, options, data_dir, .desktop, false),
        .library => {
            try verifyShellCandidate(init, options, data_dir, .nanoui_library);
            try startConsole(init, options, data_dir);
            try attachConsole(init, options, data_dir, .nanoui_library, options.assets_demo);
        },
        .desktop => try runDesktop(init, options),
        .restart => {
            try verifyRuntimeCandidate(init, options, data_dir);
            try options.context.?.requireWritableData(init.io, options.data_dir, options.launch.purpose);
            try stopConsole(init, options, data_dir);
            try startConsole(init, options, data_dir);
        },
        .stop => try stopConsole(init, options, data_dir),
        .status => {
            if (liveStatus(allocator, data_dir, options.launch.mode)) |current| {
                printSnapshot("CUTRANS_VM_STATUS", current);
            } else |err| switch (err) {
                error.HostUnavailable, error.HostTimeout => printUnreachable(try host_lifecycle.readPersisted(allocator, init.io, data_dir, options.launch.mode)),
                else => return err,
            }
        },
    }
}

fn acceptShellIdentity(runtime: *activation.Activation, allow_migration: bool, payload: []const u8, commit: bool) i32 {
    const identity = @import("host").shell_rpc.shellIdentity(payload) catch return abi.Status.invalid_arguments;
    const result = if (commit) runtime.commitShell(identity, allow_migration) else runtime.checkShell(identity, allow_migration);
    result catch |err| return switch (err) {
        error.ShellLockMismatch => abi.Status.invalid_state,
        else => abi.Status.failed,
    };
    return abi.Status.ok;
}

fn jobsReply(allocator: std.mem.Allocator, api: *const activation.Api, handle: ?*anyopaque, after_id: u64) !@import("host").shell_rpc.Reply {    var required: usize = 0;
    const query_status = api.jobs_read(handle, after_id, null, 0, &required);
    if (query_status != abi.Status.buffer_too_small) return .{ .status = if (query_status == abi.Status.ok) abi.Status.failed else query_status };
    if (required == 0 or required > max_jobs_json) return .{ .status = abi.Status.failed };
    const bytes = try allocator.alloc(u8, required);
    errdefer allocator.free(bytes);
    var actual: usize = 0;
    const status = api.jobs_read(handle, after_id, bytes.ptr, bytes.len, &actual);
    if (status != abi.Status.ok) {
        allocator.free(bytes);
        return .{ .status = status };
    }
    if (actual == 0 or actual > bytes.len) return error.InvalidRpcPayload;
    return .{ .payload = try allocator.realloc(bytes, actual), .allocator = allocator };
}

fn saveForStop(api: *const activation.Api, handle: ?*anyopaque) !void {
    // A committed output must retain its known terminal outcome across a normal
    // stop. Flushing this record never starts another queued job.
    if (api.jobs_flush(handle) != abi.Status.ok) return error.JobsFlushFailed;
    try command(api, handle, "doc.save", null);
}

pub fn runHost(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    if (!args.skip()) return error.MissingExecutableName;
    const options = try resolveOptions(init, &args);
    if (options.launch.open_path != null or options.shell_dir != null or options.replay_path != null or options.record_input != null or options.playback_frames != 0 or options.diagnose or options.headless or options.assets_demo or options.exit_demo) return error.InvalidHostArguments;
    const data_dir = try dataDirectory(init, options);
    try options.context.?.requireWritableData(init.io, options.data_dir, options.launch.purpose);
    const runtime_dir = try runtimeResourceDir(init, options, data_dir);
    var runtime = try runtime_provider.prepare(allocator, init.io, runtime_dir, data_dir, options.runtime_dir != null or options.builtin_runtime, useStaticRuntime(options));
    defer runtime.deinit();
    try claimDataDirectory(init, options, data_dir);
    var server = try host_lifecycle.Server.init(init.gpa, init.io, data_dir, options.launch.mode);
    defer server.deinit();
    const api = &runtime.api;
    const config = abi.Config{
        .struct_size = @sizeOf(abi.Config),
        .abi_version = abi.version,
        .mode = abi.modeToInt(options.launch.mode),
        .resource_dir = slice(runtime_dir),
        .data_dir = slice(data_dir),
    };
    const handle = try create(api, &config);
    defer api.destroy(handle);
    const shell_api = try shellApi(api, handle);
    try handshake(api, handle, runtime.descriptor());
    _ = try fingerprint(api, handle);
    try runtime.commit();
    var jobs_driver: @import("host").pump_driver.Driver = undefined;
    try jobs_driver.start(init.io, handle, api.jobs_pump);
    // Verification-only fault injection: commit the first workspace request,
    // then close the connection without replying. It is read once at startup so
    // the RPC path never depends on libc or on later environment changes.
    var test_drop_workspace_reply = init.environ_map.get("CUTRANS_TEST_DROP_WORKSPACE_REPLY") != null;
    // This defer is registered after Runtime.destroy, so it joins before the
    // Runtime and the function pointer's DLL can be released.
    defer jobs_driver.deinit();
    try server.ready(try fingerprint(api, handle));
    std.debug.print("CUTRANS_VM_HOST_READY boot_id={d} abnormal_previous={d}\n", .{ server.current.boot_id, @intFromBool(server.current.last_shutdown_abnormal) });
    while (true) {
        var request = server.accept() catch |err| {
            std.debug.print("[vm-host] 控制连接失败: {s}\n", .{@errorName(err)});
            try std.Io.sleep(init.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake);
            continue;
        };
        defer request.deinit();
        switch (request.action) {
            .status => {
                const document = fingerprint(api, handle) catch server.current.document_fingerprint;
                const present = presentCount(&shell_api) catch server.current.present_count;
                const current = server.snapshot(document, present);
                request.reply(current) catch {};
            },
            .prepare_stop => {
                if (server.current.state != .stopping) server.beginStop() catch |err| {
                    std.debug.print("[safe-exit] 停止受理失败: {s}\n", .{@errorName(err)});
                    request.reply(server.current) catch {};
                    continue;
                };
                request.reply(server.current) catch {};
            },
            .cancel_jobs => {
                if (server.current.state != .stopping) {
                    request.reply(server.current) catch {};
                    continue;
                }
                command(api, handle, "task.cancel_all", null) catch |err| {
                    std.debug.print("[safe-exit] 取消任务失败: {s}\n", .{@errorName(err)});
                    request.reply(server.current) catch {};
                    continue;
                };
                jobs_driver.notify();
                request.reply(server.current) catch {};
            },
            .resume_work => {
                server.resume_work() catch |err| {
                    std.debug.print("[safe-exit] 撤销退出失败: {s}\n", .{@errorName(err)});
                    request.reply(server.current) catch {};
                    continue;
                };
                request.reply(server.current) catch {};
            },
            .stop => {
                server.beginStop() catch |err| {
                    std.debug.print("[safe-exit] 停止受理失败: {s}\n", .{@errorName(err)});
                    request.reply(server.current) catch {};
                    continue;
                };
                jobs_driver.pauseAndWait();
                saveForStop(api, handle) catch {
                    server.failStop() catch |err| {
                        std.debug.print("[safe-exit] 记录降级状态失败: {s}\n", .{@errorName(err)});
                    };
                    jobs_driver.resumeWork();
                    request.reply(server.current) catch {};
                    continue;
                };
                server.completeStop() catch |err| {
                    std.debug.print("[safe-exit] 持久化停止状态失败: {s}\n", .{@errorName(err)});
                    request.reply(server.current) catch {};
                    continue;
                };
                request.reply(server.current) catch {};
                std.debug.print("CUTRANS_VM_HOST_STOPPED boot_id={d}\n", .{server.current.boot_id});
                return;
            },
            .rpc => {
                const allowed = switch (request.rpc.?.kind) {
                    .jobs_read, .shell_commit, .input_end, .frame_report, .playback_report => true,
                    else => false,
                };
                if (server.current.state == .stopping and !allowed) {
                    request.replyRpc(abi.Status.invalid_state, 0, &.{}) catch {};
                    continue;
                }
                if (request.rpc.?.kind == .jobs_read) {
                    var reply: @import("host").shell_rpc.Reply = if (request.payload.len != 0)
                        @import("host").shell_rpc.Reply{ .status = abi.Status.invalid_arguments }
                    else
                        jobsReply(init.gpa, api, handle, request.rpc.?.id) catch .{ .status = abi.Status.failed };
                    defer reply.deinit();
                    request.replyRpc(reply.status, 0, reply.payload) catch {};
                    continue;
                }
                if (request.rpc.?.kind == .input_begin) {
                    const status = api.input_begin(handle, slice(request.payload));
                    jobs_driver.notify();
                    request.replyRpc(status, 0, &.{}) catch {};
                    continue;
                }
                if (request.rpc.?.kind == .input_end) {
                    var report: abi.InputRecordReport = undefined;
                    const status = api.input_end(handle, &report);
                    jobs_driver.notify();
                    request.replyRpc(status, 0, if (status == abi.Status.ok) std.mem.asBytes(&report) else &.{}) catch {};
                    continue;
                }
                if (request.rpc.?.kind == .shell_handshake or request.rpc.?.kind == .shell_commit) {
                    const status = acceptShellIdentity(&runtime, request.rpc.?.id != 0, request.payload, request.rpc.?.kind == .shell_commit);
                    jobs_driver.notify();
                    request.replyRpc(status, 0, &.{}) catch {};
                    continue;
                }
                var reply: @import("host").shell_rpc.Reply = @import("host").shell_rpc.call(init.gpa, &shell_api, api.grant_external, request.rpc.?, request.payload) catch |err| .{
                    .status = switch (err) {
                        error.OutOfMemory => abi.Status.out_of_memory,
                        error.InvalidRpcPayload => abi.Status.invalid_arguments,
                        else => abi.Status.failed,
                    },
                };
                defer reply.deinit();
                jobs_driver.notify();
                if (test_drop_workspace_reply and request.rpc.?.kind == .workspace_submit) {
                    test_drop_workspace_reply = false;
                    std.debug.print("CUTRANS_HOST_TEST_DROPPED_REPLY\n", .{});
                    continue;
                }
                if (reply.status != abi.Status.ok and reply.status != abi.Status.accepted) std.debug.print("[shell-rpc] {s} status={d}\n", .{ @tagName(request.rpc.?.kind), reply.status });
                request.replyRpc(reply.status, reply.value, reply.payload) catch {};
            },
        }
    }
}

fn isBuiltinShell(id: []const u8) bool {
    return std.mem.eql(u8, id, "desktop-shell") or std.mem.eql(u8, id, "nanoui-library");
}

pub fn runAttached(init: std.process.Init, flavor: AttachedShell, handler: anytype) !void {
    const allocator = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    if (!args.skip()) return error.MissingExecutableName;
    const options = try resolveOptions(init, &args);
    if (options.runtime_dir != null or options.replay_path != null or options.diagnose or options.headless) return error.InvalidShellArguments;
    if (options.record_input != null and flavor != .desktop) return error.InvalidShellArguments;
    const data_dir = try dataDirectory(init, options);
    try options.context.?.requireWritableData(init.io, options.data_dir, options.launch.purpose);
    const shell_candidate = if (options.shell_dir) |path| path else try defaultShellDir(allocator, init.io, options.context.?, flavor, data_dir);
    const shell_dir = try selectedResource(init, options, shell_candidate, data_dir);
    var shell_resource_dir = try std.Io.Dir.openDirAbsolute(init.io, shell_dir, .{});
    defer shell_resource_dir.close(init.io);
    var selected_payload = if (runtime_provider.static_default)
        try payload_source.verifyCandidate(allocator, init.io, shell_resource_dir, options.shell_dir != null)
    else
        try payload_source.legacyCandidate(allocator, init.io, shell_resource_dir);
    defer selected_payload.deinit();
    const selected_shell = try packIdentity(allocator, init.io, shell_dir, selected_payload.manifest_path, selected_payload.manifest.value);
    var lock = try vne.runtime_lock.load(allocator, init.io, data_dir);
    defer if (lock) |*value| value.deinit();
    var allow_migration = options.shell_dir != null;
    if (lock) |owned| {
        if (owned.selection.shell) |locked_shell| {
            if (!vne.runtime_lock.identityEqual(locked_shell, selected_shell)) {
                // Selecting the other built-in Shell (desktop <-> library) is a
                // deliberate app switch. Replacing a payload while keeping the
                // same id is not: the manifest hash must match unless the user
                // explicitly passed --shell-dir.
                const sibling_switch = isBuiltinShell(locked_shell.id) and
                    isBuiltinShell(selected_shell.id) and
                    !std.mem.eql(u8, locked_shell.id, selected_shell.id);
                if (!allow_migration and !sibling_switch) return error.ShellLockMismatch;
                allow_migration = true;
            }
        }
    }
    try @import("shell_client").client.init(allocator, data_dir, options.launch.mode);
    defer @import("shell_client").client.deinit();
    try @import("shell_client").client.handshake(selected_shell, allow_migration);
    std.debug.print("CUTRANS_SHELL_PRECHECK_OK id={s}\n", .{selected_shell.id});
    if (!options.files_demo) if (options.launch.open_path) |path| try @import("shell_client").client.openDocument(path);
    var recording = false;
    defer if (recording) {
        if (@import("shell_client").client.inputEnd()) |report| {
            if (report.event_count > 0) std.debug.print("CUTRANS_INPUT_RECORD_OK events={d} time_ns={d}\n", .{ report.event_count, report.time_ns });
        } else |err| {
            std.debug.print("CUTRANS_INPUT_END_FAIL {s}\n", .{@errorName(err)});
        }
    };
    if (options.record_input) |path| {
        try @import("shell_client").client.inputBegin(path);
        recording = true;
    }
    const entry_path = if (runtime_provider.static_default) "" else try std.fs.path.join(allocator, &.{ shell_dir, selected_payload.manifest.value.entry });
    const config = abi.ShellConfig{
        .struct_size = @sizeOf(abi.ShellConfig),
        .abi_version = abi.version,
        .mode = abi.modeToInt(options.launch.mode),
        .resource_dir = slice(shell_dir),
        .data_dir = slice(data_dir),
        .open_path = if (options.launch.open_path) |path| slice(path) else .{},
        .playback_frames = options.playback_frames,
        .asset_workspace = if (options.exit_demo) 3 else if (options.files_demo) 2 else @intFromBool(options.assets_demo),
    };
    const shell_api = @import("shell_client").client.api();
    var exit_hooks: @import("shell_client").client.ExitHooks = .{
        .identity = selected_shell,
        .allow_migration = allow_migration,
    };
    try handler(init, entry_path, &config, &shell_api, &exit_hooks);
    if (recording) {
        const report = try @import("shell_client").client.inputEnd();
        recording = false;
        if (report.event_count > 0) std.debug.print("CUTRANS_INPUT_RECORD_OK events={d} time_ns={d}\n", .{ report.event_count, report.time_ns });
    }
    try selected_payload.verify(allocator, init.io, shell_resource_dir);
    if (!exit_hooks.committed) try @import("shell_client").client.commit(selected_shell, allow_migration);
    if (exit_hooks.host_stopped) {
        std.debug.print("CUTRANS_SAFE_EXIT_OK mode={s}\n", .{@tagName(options.launch.mode)});
    } else {
        std.debug.print("CUTRANS_SHELL_DETACHED mode={s}\n", .{@tagName(options.launch.mode)});
    }
}

pub fn runShell(init: std.process.Init) !void {
    return runAttached(init, .desktop, struct {
        fn run(process: std.process.Init, entry_path: []const u8, config: *const abi.ShellConfig, api: *const abi.ShellApi, _: anytype) !void {
            const allocator = process.arena.allocator();
            var library = try Library.open(allocator, entry_path);
            defer library.close();
            const entry = library.lookup(abi.ShellEntry, "cutrans_shell_run") orelse return error.MissingShellEntry;
            const status = entry(config, api);
            if (status != abi.Status.ok) return error.ShellAttachFailed;
        }
    }.run);
}

pub fn main(init: std.process.Init) !void {
    var probe = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer probe.deinit();
    if (!probe.skip()) return error.MissingExecutableName;
    if (probe.next()) |first| {
        if (std.mem.startsWith(u8, first, "--role=")) return error.InvalidProcessRole;
        if (consoleAction(first)) |action| {
            runConsole(init, action, &probe) catch |err| {
                std.debug.print("CUTRANS_VM_CONTROL_FAIL {s}\n", .{@errorName(err)});
                return err;
            };
            return;
        }
    }
    run(init) catch |err| {
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

test "Host job query publishes only one complete successful read" {
    var mock: JobsReadMock = .{};
    var api: activation.Api = undefined;
    api.jobs_read = JobsReadMock.read;
    var reply = try jobsReply(std.testing.allocator, &api, &mock, 41);
    defer reply.deinit();
    try std.testing.expectEqual(abi.Status.ok, reply.status);
    try std.testing.expectEqualStrings("{\"items\":[],\"next_after\":null}", reply.payload);
    try std.testing.expectEqual(@as(u64, 41), mock.after);
    mock.fail_read = true;
    var rejected = try jobsReply(std.testing.allocator, &api, &mock, 42);
    defer rejected.deinit();
    try std.testing.expectEqual(abi.Status.buffer_too_small, rejected.status);
    try std.testing.expectEqual(@as(usize, 0), rejected.payload.len);
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

test "normal Host stop requires final outcome persistence before document saving" {
    var mock: StopMock = .{};
    var api: activation.Api = undefined;
    api.jobs_flush = StopMock.flush;
    api.command = StopMock.save;
    try std.testing.expectError(error.JobsFlushFailed, saveForStop(&api, &mock));
    try std.testing.expectEqual(@as(usize, 0), mock.saves);
    mock.flush_status = abi.Status.ok;
    try std.testing.expectError(error.RuntimeCommandFailed, saveForStop(&api, &mock));
    try std.testing.expectEqual(@as(usize, 1), mock.saves);
    mock.save_status = abi.Status.ok;
    try saveForStop(&api, &mock);
    try std.testing.expectEqual(@as(usize, 2), mock.saves);
    try std.testing.expect(!mock.save_before_flush);
}
