//! diagnostics.zig — 无 GUI 的用户环境端到端诊断
//!
//! 强制读取包内示例,通过真实命令创建 DAG,导入真实 PNG、修改、导出并再解码。

const std = @import("std");
const runtime = @import("runtime");

fn expectCommand(result: runtime.command.Result) !void {
    if (result.code != .ok) return error.CommandFailed;
}

fn expectAccepted(result: runtime.command.Result) !u64 {
    if (result.code != .accepted) return error.CommandNotAccepted;
    return result.task_id orelse error.MissingTaskId;
}

fn finishExport(ctx: *runtime.context.Context, id: u64) !void {
    try runtime.document_commands.pump(ctx);
    const task = ctx.tasks.get(id) orelse return error.MissingTask;
    if (task.state != .succeeded) return error.ExportTaskFailed;
}

fn expectBytes(actual: []const u8, expected: *const [4]u8) !void {
    if (actual.len < 4) return error.InvalidFrame;
    if (!std.mem.eql(u8, actual[0..4], expected)) return error.UnexpectedPixel;
}

fn expectPixel(frame: *const runtime.render.Frame, expected: *const [4]u8) !void {
    try expectBytes(frame.pixels, expected);
}

fn writeDataFile(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn expectLoadFailure(expected: runtime.capabilities.Failure, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    _ = runtime.image.load(allocator, io, dir, path) catch |err| {
        if (runtime.capabilities.classifyError(err) != expected) return error.UnexpectedFailureClass;
        return;
    };
    return error.ExpectedLoadFailure;
}

const RunOptions = struct {
    mode: runtime.paths.Mode,
    mode_seen: bool,
    purpose: @import("vne").launch.Purpose,
    data_dir: ?[]const u8,
    open_path: ?[]const u8,
    inspect: bool,
};

fn parseArgs(args: *std.process.Args.Iterator) !RunOptions {
    var launch: runtime.paths.LaunchOptions = .{};
    var data_dir: ?[]const u8 = null;
    var inspect = false;
    while (args.next()) |arg| {
        if (try runtime.paths.parseLaunchArg(&launch, args, arg)) continue;
        if (std.mem.startsWith(u8, arg, "--verify-data-dir=")) {
            if (data_dir != null) return error.DuplicateDataDirectory;
            data_dir = arg["--verify-data-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--inspect")) {
            if (inspect) return error.InvalidArgument;
            inspect = true;
        } else return error.InvalidArgument;
    }
    if (!inspect and data_dir == null) return error.VerificationRequiresExplicitDataDirectory;
    if (!inspect and launch.purpose_seen and launch.purpose == .normal) return error.InvalidDiagnosticPurpose;
    return .{ .mode = launch.mode, .mode_seen = launch.mode_seen, .purpose = if (launch.purpose_seen) launch.purpose else .diagnostic, .data_dir = data_dir, .open_path = launch.open_path, .inspect = inspect };
}

fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    if (!args.skip()) return error.MissingExecutableName;
    const options = try parseArgs(&args);
    const exe_dir = try std.process.executableDirPathAlloc(init.io, arena);
    var environment = try @import("vne").environment.load(arena, init.io, exe_dir);
    defer environment.deinit();
    const mode = try environment.validateMode(if (options.mode_seen) options.mode else null);

    var paths: runtime.paths.Paths = .{};
    try paths.init(arena, init.io, mode, init.environ_map);
    if (options.inspect) {
        const json = try std.json.Stringify.valueAlloc(arena, .{
            .product_id = @import("vne").product.id,
            .version = @import("vne").product.version,
            .channel = @tagName(environment.channel),
            .form = @tagName(mode),
            .purpose = "inspect",
            .product_root = environment.product_root,
            .resource_dir = paths.resource_dir,
            .data_dir = paths.data_dir,
            .services = .{ .updates = false, .accounts = false, .telemetry = false },
        }, .{});
        std.debug.print("CUTRANS_CONTEXT_JSON {s}\n", .{json});
        return;
    }
    const verify_data = try @import("vne").environment.canonicalPath(arena, init.io, options.data_dir.?);
    try environment.requireWritableData(init.io, verify_data, options.purpose);
    try @import("vne").environment.ensureSeparate(arena, init.io, paths.data_dir, verify_data);
    try @import("vne").environment.ensureSeparate(arena, init.io, paths.resource_dir, verify_data);
    try paths.overrideDataDir(arena, verify_data);
    var resource_dir = try paths.openResourceDir(init.io);
    defer resource_dir.close(init.io);
    const pack_report = try runtime.vm_pack.verifyFile(arena, init.io, resource_dir);
    try environment.checkInstance(init.io, paths.data_dir, options.purpose, true);
    if (std.mem.eql(u8, paths.resource_dir, paths.data_dir)) return error.SharedResourceAndDataDirectory;
    std.debug.print("CUTRANS_PATHS mode={s} resource={s} data={s}\n", .{ @tagName(mode), paths.resource_dir, paths.data_dir });

    var ctx: runtime.context.Context = undefined;
    ctx.init(arena);
    defer ctx.deinit();
    ctx.io = init.io;
    ctx.paths = paths;
    try @import("runtime").mounts.configure(&ctx);
    runtime.document_commands.register(&ctx);
    if (try runtime.document_commands.restore(&ctx) != 0) return error.UnexpectedRecoveredTask;
    if (options.open_path) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.ExternalDiagnosticRequiresAbsolutePath;
        const grant_id = try ctx.mounts.grantExternal(arena, path, .read_only);
        var uri_buffer: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&uri_buffer, "external://{d}", .{grant_id});
        try expectCommand(ctx.command.dispatch(.{ .name = "doc.open", .arg = uri }));
        const fingerprint = ctx.document.fingerprint();
        var verification_dir = try ctx.paths.openDataDir(init.io, arena);
        defer verification_dir.close(init.io);
        try runtime.documents.save(&ctx.document, init.io, arena, verification_dir, "documents/external-copy.cut");
        var external = runtime.documents.Document.initDefault();
        try runtime.documents.open(&external, init.io, arena, verification_dir, "documents/external-copy.cut");
        if (fingerprint != external.fingerprint()) return error.ExternalDocumentChangedAfterRoundTrip;
        std.debug.print("CUTRANS_OPEN_OK path={s} nodes={d} original_write=0\n", .{ path, external.count });
        // The media probe has its own deterministic fixture, independent of user work.
        ctx.document = runtime.documents.Document.initDefault();
    }

    std.debug.print("CUTRANS_PACK capabilities={d} files={d} native={d}\n", .{ pack_report.capabilities, pack_report.files, pack_report.native_dependencies });
    // Pack files are immutable inputs. Round-trip writes belong only to verification data.

    var preview: runtime.render.Preview = .{};
    defer preview.deinit(arena);
    try expectPixel(try preview.currentWithDir(&ctx.document, arena, init.io, resource_dir), &.{ 26, 77, 153, 255 });

    try expectCommand(ctx.command.dispatch(.{ .name = "editor.gain.set", .arg = "c1 0.25" }));
    try expectCommand(ctx.command.dispatch(.{ .name = "editor.invert.add", .arg = "c1" }));
    try expectCommand(ctx.command.dispatch(.{ .name = "editor.over.add", .arg = "c0 c2 0.25" }));
    if (ctx.document.count != 4) return error.UnexpectedNodeCount;
    try expectPixel(try preview.currentWithDir(&ctx.document, arena, init.io, resource_dir), &.{ 86, 129, 195, 255 });
    try expectCommand(ctx.command.dispatch(.{ .name = "history.undo" }));
    if (ctx.document.count != 3) return error.UnexpectedUndoNodeCount;
    try expectCommand(ctx.command.dispatch(.{ .name = "history.redo" }));
    if (ctx.document.count != 4) return error.UnexpectedRedoNodeCount;

    var data_dir = try ctx.paths.openDataDir(init.io, arena);
    defer data_dir.close(init.io);

    const capability_report = runtime.capabilities.inspect();
    if (!capability_report.audit.ok()) return error.CapabilityAuditFailed;
    var ready_capabilities: usize = 0;
    for (capability_report.entries) |entry| {
        if (entry.status == .ready) ready_capabilities += 1;
    }
    if (ready_capabilities != capability_report.entries.len) return error.CapabilityNotReady;
    try writeDataFile(data_dir, init.io, "unsupported.img", "not png!");
    try writeDataFile(data_dir, init.io, "truncated.png", &.{ 0x89, 'P', 'N', 'G' });
    try expectLoadFailure(.unsupported, arena, init.io, data_dir, "unsupported.img");
    try expectLoadFailure(.corrupt, arena, init.io, data_dir, "truncated.png");
    try expectLoadFailure(.missing, arena, init.io, data_dir, "missing.png");

    try runtime.documents.save(&ctx.document, init.io, arena, data_dir, "documents/session.cut");

    var restored = runtime.documents.Document.initDefault();
    try runtime.documents.open(&restored, init.io, arena, data_dir, "documents/session.cut");
    if (ctx.document.fingerprint() != restored.fingerprint()) return error.DocumentChangedAfterRoundTrip;
    try expectPixel(try preview.currentWithDir(&restored, arena, init.io, resource_dir), &.{ 86, 129, 195, 255 });

    data_dir.deleteFile(init.io, "exports/output.png") catch |err| {
        if (err != error.FileNotFound) return err;
    };
    const cancelled_id = try expectAccepted(ctx.command.dispatch(.{ .name = "editor.export.png" }));
    var task_arg_buffer: [32]u8 = undefined;
    const task_arg = try std.fmt.bufPrint(&task_arg_buffer, "{d}", .{cancelled_id});
    try expectCommand(ctx.command.dispatch(.{ .name = "task.cancel", .arg = task_arg }));
    if (ctx.tasks.get(cancelled_id).?.state != .cancelled) return error.TaskNotCancelled;
    try runtime.document_commands.pump(&ctx);
    try expectLoadFailure(.missing, arena, init.io, data_dir, "exports/output.png");

    const dag_task_id = try expectAccepted(ctx.command.dispatch(.{ .name = "editor.export.png" }));
    try finishExport(&ctx, dag_task_id);
    var dag_export = try runtime.image.load(arena, init.io, data_dir, "exports/output.png");
    defer dag_export.deinit(arena);
    try expectBytes(dag_export.pixels, &.{ 86, 129, 195, 255 });

    try expectCommand(ctx.command.dispatch(.{ .name = "editor.image.open" }));
    if (ctx.document.width != 91 or ctx.document.height != 69 or ctx.document.count != 1) return error.UnexpectedImageMetadata;
    try expectCommand(ctx.command.dispatch(.{ .name = "history.undo" }));
    if (ctx.document.count != 4) return error.UnexpectedImageUndo;
    try expectCommand(ctx.command.dispatch(.{ .name = "history.redo" }));
    if (ctx.document.count != 1) return error.UnexpectedImageRedo;
    const original_frame = try preview.currentWithDir(&ctx.document, arena, init.io, resource_dir);
    var original: [4]u8 = undefined;
    @memcpy(&original, original_frame.pixels[0..4]);

    var comp_arg: [64]u8 = undefined;
    try expectCommand(ctx.command.dispatch(.{ .name = "editor.invert.add", .arg = try std.fmt.bufPrint(&comp_arg, "c{d}", .{ctx.document.outputId().?}) }));
    const inverted_expected = [4]u8{ 255 - original[0], 255 - original[1], 255 - original[2], original[3] };
    try expectCommand(ctx.command.dispatch(.{ .name = "editor.resize.add", .arg = try std.fmt.bufPrint(&comp_arg, "c{d} 182 138", .{ctx.document.outputId().?}) }));
    if (ctx.document.width != 182 or ctx.document.height != 138) return error.UnexpectedResizeMetadata;
    try expectPixel(try preview.currentWithDir(&ctx.document, arena, init.io, resource_dir), &inverted_expected);

    try runtime.documents.save(&ctx.document, init.io, arena, data_dir, "documents/image.cut");
    var restored_image = runtime.documents.Document.initDefault();
    try runtime.documents.open(&restored_image, init.io, arena, data_dir, "documents/image.cut");
    if (!std.mem.eql(u8, restored_image.nodes[0].asset(), "pack://assets/examples/pngtest.png")) return error.NonCanonicalAssetUri;
    const image_text = try runtime.documents.emitAlloc(&restored_image, arena);
    defer arena.free(image_text);
    if (!std.mem.startsWith(u8, image_text, "version=3\n") or std.mem.indexOf(u8, image_text, "pack://assets/examples/pngtest.png") == null) return error.MissingVneAssetUri;
    try expectPixel(try preview.currentWithDir(&restored_image, arena, init.io, resource_dir), &inverted_expected);

    const image_task_id = try expectAccepted(ctx.command.dispatch(.{ .name = "editor.export.png" }));
    try finishExport(&ctx, image_task_id);
    var image_export = try runtime.image.load(arena, init.io, data_dir, "exports/output.png");
    defer image_export.deinit(arena);
    if (image_export.width != 182 or image_export.height != 138) return error.UnexpectedExportMetadata;
    try expectBytes(image_export.pixels, &inverted_expected);

    const interrupted_id = try expectAccepted(ctx.command.dispatch(.{ .name = "editor.export.png" }));
    var recovered_ctx: runtime.context.Context = undefined;
    recovered_ctx.init(arena);
    defer recovered_ctx.deinit();
    recovered_ctx.io = init.io;
    recovered_ctx.paths = try runtime.paths.Paths.fromDirs(arena, mode, paths.resource_dir, paths.data_dir);
    runtime.document_commands.register(&recovered_ctx);
    if (try runtime.document_commands.restore(&recovered_ctx) != 1) return error.TaskRecoveryFailed;
    if (recovered_ctx.tasks.get(interrupted_id).?.state != .interrupted) return error.TaskNotInterrupted;
    if (runtime.document_commands.jobsPending(&recovered_ctx)) return error.RecoveredExportShouldNotRun;
    if (recovered_ctx.document.fingerprint() != ctx.document.fingerprint()) return error.HistoryDocumentChangedAfterRestore;
    if (recovered_ctx.history.count == 0) return error.HistoryNotRestored;
    try expectCommand(recovered_ctx.command.dispatch(.{ .name = "history.undo" }));
    if (recovered_ctx.document.width != 91 or recovered_ctx.document.height != 69) return error.RestoredUndoFailed;
    try expectCommand(recovered_ctx.command.dispatch(.{ .name = "history.redo" }));
    if (recovered_ctx.document.fingerprint() != ctx.document.fingerprint()) return error.RestoredRedoFailed;

    std.debug.print("CUTRANS_DIAG_OK mode={s} evaluations={d} nodes={d} png={d}x{d} capabilities={d}/{d} audit=ok pack=ok tasks={d} recovered=1 history={d}\n", .{
        @tagName(mode),
        preview.evaluation_count,
        restored_image.count,
        image_export.width,
        image_export.height,
        ready_capabilities,
        capability_report.entries.len,
        ctx.tasks.count,
        recovered_ctx.history.count,
    });
}

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        std.debug.print("CUTRANS_DIAG_FAIL {s}\n", .{@errorName(err)});
        return err;
    };
}
