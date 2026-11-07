const std = @import("std");
const abi = @import("vne").abi;
const RuntimeContext = @import("context.zig").Context;
const paths = @import("paths.zig");
const command = @import("command.zig");
const document_commands = @import("document_commands.zig");
const workspace = @import("vne").workspace;
const document_requests = @import("document_requests.zig");
const resource_api = @import("vne").resource_api;
const resource_requests = @import("resource_requests.zig");

const allocator = std.heap.c_allocator;
const max_string_size = 1024 * 1024;

const Runtime = struct {
    io: std.Io.Threaded,
    ctx: RuntimeContext,
    input_recording: @import("input_recording.zig").Recorder,
    last_playback_log_t: i64,
    epoch: [2]u64,
    mutex: std.Io.Mutex,
    requests: document_requests.Registry,
    resource_registry: resource_requests.Registry,
    execution_gate: std.Io.Mutex = .init,
    work_ready: std.Io.Semaphore = .{},
    work_done: std.Io.Semaphore = .{},
    work: ?struct { invoke: *const fn (*anyopaque) void, context: *anyopaque } = null,
    stopping: bool = false,
    worker: std.Thread,
    jobs_gate: std.Io.Mutex = .init,
    render_ready: std.Io.Semaphore = .{},
    render_done: std.Io.Semaphore = .{},
    render_work: ?*RenderTask = null,
    render_stopping: bool = false,
    render_worker: std.Thread,
    shell_driver: ?*@import("vne").job_driver.Driver = null,
    // Private deterministic barrier for source-level concurrency tests only.
    before_compute: ?*const fn (*anyopaque) void = null,
    compute_observer: ?*anyopaque = null,

    fn create(config: abi.Config) !*Runtime {
        if (!std.fs.path.isAbsolute(config.resource_dir.ptr.?[0..config.resource_dir.len]) or
            !std.fs.path.isAbsolute(config.data_dir.ptr.?[0..config.data_dir.len])) return error.InvalidPath;
        if (std.mem.eql(u8, config.resource_dir.ptr.?[0..config.resource_dir.len], config.data_dir.ptr.?[0..config.data_dir.len])) return error.SharedResourceAndDataDirectory;
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.execution_gate = .init;
        self.work_ready = .{};
        self.work_done = .{};
        self.work = null;
        self.stopping = false;
        self.jobs_gate = .init;
        self.render_ready = .{};
        self.render_done = .{};
        self.render_work = null;
        self.render_stopping = false;
        self.shell_driver = null;
        self.before_compute = null;
        self.compute_observer = null;
        self.input_recording = .{};
        self.last_playback_log_t = -1;
        self.io = std.Io.Threaded.init(allocator, .{});
        errdefer self.io.deinit();
        self.mutex = .init;
        self.requests = document_requests.Registry.init(allocator);
        errdefer self.requests.deinit();
        self.resource_registry = resource_requests.Registry.init(allocator);
        errdefer self.resource_registry.deinit();
        try self.io.io().randomSecure(std.mem.asBytes(&self.epoch));
        if (self.epoch[0] == 0 and self.epoch[1] == 0) return error.EntropyUnavailable;
        self.ctx.init(allocator);
        errdefer self.ctx.deinit();
        self.ctx.io = self.io.io();
        self.ctx.runtime_origin = .{ .epoch_hi = self.epoch[0], .epoch_lo = self.epoch[1], .revision = 1 };
        self.ctx.clock = .{ .system = self.ctx.io };
        self.ctx.paths = try paths.Paths.fromDirsPhysical(allocator, self.ctx.io.?, try abi.modeFromInt(config.mode), config.resource_dir.ptr.?[0..config.resource_dir.len], config.data_dir.ptr.?[0..config.data_dir.len]);
        try @import("mounts.zig").configure(&self.ctx);
        document_commands.register(&self.ctx);
        _ = try document_commands.restore(&self.ctx);
        self.render_worker = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, runRenderWorker, .{self});
        errdefer {
            self.render_stopping = true;
            self.render_ready.post(self.io.io());
            self.render_worker.join();
        }
        self.worker = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, runWorker, .{self});
        return self;
    }

    fn destroy(self: *Runtime) void {
        const io_value = self.io.io();
        // An attempt may need the owner for its final commit. Wait for the
        // attempt before taking the owner gate, then join both before deinit.
        self.jobs_gate.lockUncancelable(io_value);
        self.execution_gate.lockUncancelable(io_value);
        self.stopping = true;
        self.work_ready.post(io_value);
        self.worker.join();
        self.execution_gate.unlock(io_value);
        self.render_stopping = true;
        self.render_ready.post(io_value);
        self.render_worker.join();
        self.jobs_gate.unlock(io_value);
        self.requests.deinit();
        self.resource_registry.deinit();
        self.input_recording.deinit();
        self.ctx.deinit();
        self.io.deinit();
        allocator.destroy(self);
    }

    fn runWorker(self: *Runtime) void {
        const io_value = self.io.io();
        while (true) {
            self.work_ready.waitUncancelable(io_value);
            if (self.stopping) return;
            const work = self.work.?;
            self.mutex.lockUncancelable(io_value);
            work.invoke(work.context);
            if (self.shell_driver) |driver| if (document_commands.jobsPending(&self.ctx)) driver.notify();
            self.mutex.unlock(io_value);
            self.work_done.post(io_value);
        }
    }

    fn runRenderWorker(self: *Runtime) void {
        const io_value = self.io.io();
        while (true) {
            self.render_ready.waitUncancelable(io_value);
            if (self.render_stopping) return;
            const task = self.render_work.?;
            if (task.before_compute) |observe| observe(task.observer.?);
            task.result = task.work.compute(task.io, task.cancel);
            self.render_done.post(io_value);
        }
    }

    /// One bounded synchronous inbox. Borrowed caller bytes remain live until
    /// completion; command/submit/pump execute on the same persistent VM stack.
    fn execute(self: *Runtime, comptime T: type, task: *T) void {
        const Adapter = struct {
            fn invoke(pointer: *anyopaque) void {
                const value: *T = @ptrCast(@alignCast(pointer));
                value.run();
            }
        };
        const io_value = self.io.io();
        self.execution_gate.lockUncancelable(io_value);
        defer self.execution_gate.unlock(io_value);
        self.work = .{ .invoke = Adapter.invoke, .context = task };
        self.work_ready.post(io_value);
        self.work_done.waitUncancelable(io_value);
        self.work = null;
    }

    const CreateTask = struct {
        config: abi.Config,
        result: anyerror!*Runtime,

        fn run(self: *@This()) void {
            self.result = Runtime.create(self.config);
        }
    };

    fn createOnOwnedStack(config: abi.Config) !*Runtime {
        var task: CreateTask = .{ .config = config, .result = undefined };
        const thread = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, CreateTask.run, .{&task});
        thread.join();
        return task.result;
    }

    const CommandTask = struct {
        runtime: *Runtime,
        name: []const u8,
        arg: ?[]const u8,
        result: command.Result = undefined,

        fn run(self: *@This()) void {
            self.result = self.runtime.ctx.command.dispatch(.{ .name = self.name, .arg = self.arg });
        }
    };

    fn commandOnOwnedStack(self: *Runtime, name: []const u8, arg: ?[]const u8) !command.Result {
        var task: CommandTask = .{ .runtime = self, .name = name, .arg = arg };
        self.execute(CommandTask, &task);
        return task.result;
    }

    const ReadSourceTask = struct {
        runtime: *Runtime,
        uri: []const u8,
        expected: ?[32]u8,
        buffer: ?[*]u8,
        capacity: usize,
        length: *usize,
        result: i32 = abi.Status.failed,

        fn run(self: *@This()) void {
            var loaded = @import("assets.zig").readVersion(&self.runtime.ctx, self.uri, self.expected) catch |err| {
                self.result = report(err);
                return;
            };
            defer loaded.deinit(allocator);
            self.result = copyBytes(loaded.bytes, self.buffer, self.capacity, self.length);
        }
    };

    const SubmitTask = struct {
        runtime: *Runtime,
        request: *const workspace.Request,
        name: []const u8,
        arg: ?[]const u8,
        result: anyerror!workspace.Outcome = undefined,

        fn run(self: *@This()) void {
            self.result = self.runtime.requests.submit(&self.runtime.ctx, self.runtime.epoch, self.request, self.name, self.arg);
        }
    };

    fn submitOnOwnedStack(self: *Runtime, request: *const workspace.Request, name: []const u8, arg: ?[]const u8) !workspace.Outcome {
        var task = SubmitTask{ .runtime = self, .request = request, .name = name, .arg = arg };
        self.execute(SubmitTask, &task);
        return task.result;
    }

    const ResourceSnapshotTask = struct {
        runtime: *Runtime,
        expected: ?resource_api.Stamp,
        out: *resource_api.Snapshot,
        buffer: ?[*]u8,
        capacity: usize,
        length: *usize,
        result: i32 = abi.Status.failed,

        fn run(self: *@This()) void {
            const current = resource_requests.stamp(&self.runtime.ctx, self.runtime.epoch);
            self.out.* = .{ .stamp = current, .text_len = 0 };
            if (self.expected) |expected| {
                if (expected.epoch_hi != current.epoch_hi or expected.epoch_lo != current.epoch_lo) {
                    self.result = resource_api.Status.wrong_epoch;
                    return;
                }
                if (!expected.eql(current)) {
                    self.result = resource_api.Status.stale_version;
                    return;
                }
            }
            const bytes = resource_requests.snapshotText(&self.runtime.ctx) catch |err| {
                self.result = resource_requests.status(err);
                return;
            };
            defer allocator.free(bytes);
            self.out.text_len = bytes.len;
            self.result = copyBytes(bytes, self.buffer, self.capacity, self.length);
        }
    };

    const ResourceProbeTask = struct {
        runtime: *Runtime,
        request: *const resource_api.ProbeRequest,
        path: []const u8,
        result: anyerror!resource_api.Proof = undefined,

        fn run(self: *@This()) void {
            self.result = resource_requests.probe(&self.runtime.ctx, self.runtime.epoch, self.request, self.path);
        }
    };

    const ResourceSubmitTask = struct {
        runtime: *Runtime,
        request: *const resource_api.Request,
        path: []const u8,
        result: anyerror!resource_api.Outcome = undefined,

        fn run(self: *@This()) void {
            self.result = self.runtime.resource_registry.submit(&self.runtime.ctx, self.runtime.epoch, self.request, self.path);
        }
    };

    const FlushTask = struct {
        runtime: *Runtime,
        result: anyerror!void = undefined,
        fn run(self: *@This()) void {
            self.result = document_commands.flushJobRecord(&self.runtime.ctx);
        }
    };

    const PlaybackTask = struct {
        runtime: *Runtime,
        result: anyerror!void = undefined,
        fn run(self: *@This()) void {
            self.result = self.runtime.ctx.playback.pump(&self.runtime.ctx);
        }
    };

    const BeginTask = struct {
        runtime: *Runtime,
        result: anyerror!?document_commands.Work = undefined,
        fn run(self: *@This()) void {
            self.result = document_commands.beginExport(&self.runtime.ctx);
        }
    };

    const RenderTask = struct {
        work: *document_commands.Work,
        io: std.Io,
        cancel: *const std.atomic.Value(bool),
        before_compute: ?*const fn (*anyopaque) void,
        observer: ?*anyopaque,
        result: document_commands.Computed = undefined,
    };

    const FinishTask = struct {
        runtime: *Runtime,
        work: *document_commands.Work,
        computed: *document_commands.Computed,
        result: anyerror!void = undefined,
        fn run(self: *@This()) void {
            defer self.work.deinit();
            defer self.computed.deinit(self.runtime.io.io());
            self.result = document_commands.finishExport(&self.runtime.ctx, self.work.job.task_id, self.computed);
        }
    };

    fn pumpOnOwnedStack(self: *Runtime, jobs_only: bool) !void {
        if (!jobs_only) {
            var playback = PlaybackTask{ .runtime = self };
            self.execute(PlaybackTask, &playback);
            try playback.result;
        }
        const io_value = self.io.io();
        if (jobs_only) self.jobs_gate.lockUncancelable(io_value) else if (!self.jobs_gate.tryLock()) return;
        defer self.jobs_gate.unlock(io_value);
        var begin = BeginTask{ .runtime = self };
        self.execute(BeginTask, &begin);
        var work = (try begin.result) orelse return;
        var render_task = RenderTask{ .work = &work, .io = io_value, .cancel = &self.ctx.active_cancel, .before_compute = self.before_compute, .observer = self.compute_observer };
        self.render_work = &render_task;
        self.render_ready.post(io_value);
        self.render_done.waitUncancelable(io_value);
        self.render_work = null;
        var finish = FinishTask{ .runtime = self, .work = &work, .computed = &render_task.result };
        self.execute(FinishTask, &finish);
        return finish.result;
    }
};

fn read(bytes: abi.ByteSlice, required: bool) !?[]const u8 {
    if (bytes.len == 0) {
        if (required) return error.MissingString;
        return null;
    }
    if (bytes.len > max_string_size) return error.StringTooLong;
    const ptr = bytes.ptr orelse return error.MissingString;
    return ptr[0..bytes.len];
}

fn from(handle: ?*anyopaque) !*Runtime {
    const opaque_handle = handle orelse return error.InvalidHandle;
    return @ptrCast(@alignCast(opaque_handle));
}

fn report(err: anyerror) i32 {
    std.debug.print("[vm-runtime] {s}\n", .{@errorName(err)});
    return switch (err) {
        error.OutOfMemory => abi.Status.out_of_memory,
        error.FileNotFound => abi.Status.not_found,
        error.InvalidHandle => abi.Status.invalid_handle,
        error.InvalidMode => abi.Status.abi_mismatch,
        error.LegacyExternalIdentityUnverified => abi.Status.legacy_identity_unverified,
        else => abi.Status.failed,
    };
}

fn commandCode(code: command.Code) i32 {
    return switch (code) {
        .ok => abi.Status.ok,
        .accepted => abi.Status.accepted,
        .unknown_command => abi.Status.unknown_command,
        .invalid_arguments => abi.Status.invalid_arguments,
        .permission_denied => abi.Status.permission_denied,
        .invalid_state => abi.Status.invalid_state,
        .not_ready => abi.Status.not_ready,
        .queue_full => abi.Status.queue_full,
        .failed => abi.Status.failed,
        .cancelled => abi.Status.cancelled,
    };
}

export fn cutrans_vm_abi_version() callconv(.c) u32 {
    return abi.version;
}

export fn cutrans_vm_create(config: ?*const abi.Config, out_handle: ?*?*anyopaque) callconv(.c) i32 {
    const out = out_handle orelse return abi.Status.invalid_arguments;
    out.* = null;
    const value = config orelse return abi.Status.invalid_arguments;
    if (value.struct_size < @sizeOf(abi.Config) or value.abi_version != abi.version) return abi.Status.abi_mismatch;
    if (value.reserved != 0) return abi.Status.invalid_arguments;
    _ = read(value.resource_dir, true) catch |err| return report(err);
    _ = read(value.data_dir, true) catch |err| return report(err);
    const runtime = Runtime.createOnOwnedStack(value.*) catch |err| return report(err);
    out.* = runtime;
    return abi.Status.ok;
}

export fn cutrans_vm_destroy(handle: ?*anyopaque) callconv(.c) void {
    const runtime = from(handle) catch return;
    runtime.destroy();
}

export fn cutrans_vm_command_result(handle: ?*anyopaque, name: abi.ByteSlice, arg: abi.ByteSlice, out_task_id: ?*u64) callconv(.c) i32 {
    if (out_task_id) |out| out.* = 0;
    const runtime = from(handle) catch |err| return report(err);
    const command_name = read(name, true) catch |err| return report(err);
    const command_arg = read(arg, false) catch |err| return report(err);
    const result = runtime.commandOnOwnedStack(command_name.?, command_arg) catch |err| return report(err);
    if (out_task_id) |out| out.* = result.task_id orelse 0;
    return commandCode(result.code);
}

export fn cutrans_vm_command(handle: ?*anyopaque, name: abi.ByteSlice, arg: abi.ByteSlice) callconv(.c) i32 {
    return cutrans_vm_command_result(handle, name, arg, null);
}

export fn cutrans_vm_workspace_api(handle: ?*anyopaque, out_api: ?*workspace.Api) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    const out = out_api orelse return abi.Status.invalid_arguments;
    out.* = .{ .context = runtime, .snapshot = cutrans_vm_document_snapshot, .submit = cutrans_vm_document_submit };
    return abi.Status.ok;
}

export fn cutrans_vm_resource_api(handle: ?*anyopaque, out_api: ?*resource_api.Api) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    const out = out_api orelse return abi.Status.invalid_arguments;
    out.* = .{ .context = runtime, .snapshot = cutrans_vm_resource_snapshot, .probe = cutrans_vm_resource_probe, .submit = cutrans_vm_resource_submit };
    return abi.Status.ok;
}

fn resourcePath(value: resource_api.Bytes) ![]const u8 {
    if (value.len == 0 or value.len > resource_api.max_path_size) return error.InvalidArguments;
    const pointer = value.ptr orelse return error.InvalidArguments;
    const path = pointer[0..value.len];
    if (!resource_api.validPath(path) or !std.fs.path.isAbsolute(path)) return error.InvalidArguments;
    return path;
}

export fn cutrans_vm_resource_snapshot(handle: ?*anyopaque, expected: ?*const resource_api.Stamp, out_snapshot: ?*resource_api.Snapshot, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) callconv(.c) i32 {
    const required = out_len orelse return abi.Status.invalid_arguments;
    required.* = 0;
    const out = out_snapshot orelse return abi.Status.invalid_arguments;
    if (buffer != null and expected == null) return abi.Status.invalid_arguments;
    const runtime = from(handle) catch |err| return report(err);
    var task = Runtime.ResourceSnapshotTask{ .runtime = runtime, .expected = if (expected) |value| value.* else null, .out = out, .buffer = buffer, .capacity = buffer_len, .length = required };
    runtime.execute(Runtime.ResourceSnapshotTask, &task);
    return task.result;
}

export fn cutrans_vm_resource_probe(handle: ?*anyopaque, request: ?*const resource_api.ProbeRequest, out_proof: ?*resource_api.Proof) callconv(.c) i32 {
    const value = request orelse return abi.Status.invalid_arguments;
    const out = out_proof orelse return abi.Status.invalid_arguments;
    if (value.struct_size != @sizeOf(resource_api.ProbeRequest) or value.api_version != resource_api.version) return abi.Status.abi_mismatch;
    if (value.reserved != 0 or std.enums.fromInt(resource_api.Mode, value.mode) == null) return abi.Status.invalid_arguments;
    const path = resourcePath(value.path) catch return abi.Status.invalid_arguments;
    const runtime = from(handle) catch |err| return report(err);
    var task = Runtime.ResourceProbeTask{ .runtime = runtime, .request = value, .path = path };
    runtime.execute(Runtime.ResourceProbeTask, &task);
    out.* = task.result catch |err| return resource_requests.status(err);
    return abi.Status.ok;
}

export fn cutrans_vm_resource_submit(handle: ?*anyopaque, request: ?*const resource_api.Request, out_outcome: ?*resource_api.Outcome) callconv(.c) i32 {
    const value = request orelse return abi.Status.invalid_arguments;
    const out = out_outcome orelse return abi.Status.invalid_arguments;
    if (value.struct_size != @sizeOf(resource_api.Request) or value.api_version != resource_api.version or
        value.proof.struct_size != @sizeOf(resource_api.Proof) or value.proof.api_version != resource_api.version) return abi.Status.abi_mismatch;
    if (!resource_api.validProof(&value.proof)) return abi.Status.invalid_arguments;
    const path = resourcePath(value.path) catch return abi.Status.invalid_arguments;
    const runtime = from(handle) catch |err| return report(err);
    var task = Runtime.ResourceSubmitTask{ .runtime = runtime, .request = value, .path = path };
    runtime.execute(Runtime.ResourceSubmitTask, &task);
    out.* = task.result catch |err| return resource_requests.status(err);
    return abi.Status.ok;
}

test "resource ABI rejects malformed requests before execution and clears failed snapshot length" {
    var length: usize = 99;
    var metadata: resource_api.Snapshot = undefined;
    try std.testing.expectEqual(abi.Status.invalid_handle, cutrans_vm_resource_snapshot(null, null, &metadata, null, 0, &length));
    try std.testing.expectEqual(@as(usize, 0), length);
    const proof = resource_api.Proof{ .stamp = .{}, .target_id = 1, .mode = 1, .head_hash = @splat(1), .content_hash = @splat(2), .path_hash = @splat(3), .byte_length = 4, .volume_serial = 5, .file_index = 6 };
    var output = proof;
    const relative = "relative.png";
    var probe = resource_api.ProbeRequest{ .expected = .{}, .target_id = 1, .mode = 1, .path = .{ .ptr = relative.ptr, .len = relative.len } };
    try std.testing.expectEqual(abi.Status.invalid_arguments, cutrans_vm_resource_probe(null, &probe, &output));
    try std.testing.expectEqualDeep(proof, output);
    probe.struct_size -= 1;
    try std.testing.expectEqual(abi.Status.abi_mismatch, cutrans_vm_resource_probe(null, &probe, &output));
    var request = resource_api.Request{ .client_hi = 1, .client_lo = 2, .sequence = 1, .proof = proof, .path = .{ .ptr = relative.ptr, .len = relative.len } };
    var outcome: resource_api.Outcome = undefined;
    try std.testing.expectEqual(abi.Status.invalid_arguments, cutrans_vm_resource_submit(null, &request, &outcome));
    request.proof.reserved = 1;
    try std.testing.expectEqual(abi.Status.invalid_arguments, cutrans_vm_resource_submit(null, &request, &outcome));
}

export fn cutrans_vm_document_snapshot(handle: ?*anyopaque, expected: ?*const workspace.Stamp, out_snapshot: ?*workspace.Snapshot, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    const out = out_snapshot orelse return abi.Status.invalid_arguments;
    const required = out_len orelse return abi.Status.invalid_arguments;
    required.* = 0;
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const stamp = document_requests.Registry.stamp(&runtime.ctx, runtime.epoch);
    out.* = .{ .stamp = stamp, .fingerprint = runtime.ctx.document.fingerprint(), .node_id_high_water = runtime.ctx.document.nodeIdHighWater(), .flags = @as(u32, @intFromBool(runtime.ctx.document.dirty)) | (@as(u32, @intFromBool(runtime.ctx.document.legacy)) << 1), .text_len = 0 };
    if (expected) |value| {
        if (value.epoch_hi != stamp.epoch_hi or value.epoch_lo != stamp.epoch_lo) return workspace.Status.wrong_epoch;
        if (!value.eql(stamp)) return workspace.Status.stale_version;
    } else if (buffer != null) return abi.Status.invalid_arguments;
    const text = @import("documents.zig").emitAlloc(&runtime.ctx.document, allocator) catch |err| return report(err);
    defer allocator.free(text);
    required.* = text.len;
    out.text_len = text.len;
    const output = buffer orelse return abi.Status.buffer_too_small;
    if (buffer_len < text.len) return abi.Status.buffer_too_small;
    @memcpy(output[0..text.len], text);
    return abi.Status.ok;
}

export fn cutrans_vm_document_submit(handle: ?*anyopaque, request: ?*const workspace.Request, out_outcome: ?*workspace.Outcome) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    const value = request orelse return abi.Status.invalid_arguments;
    const out = out_outcome orelse return abi.Status.invalid_arguments;
    if (value.struct_size != @sizeOf(workspace.Request) or value.api_version != workspace.version) return abi.Status.abi_mismatch;
    if (value.name.len == 0 or value.name.len > 64 or value.arg.len > max_string_size) return abi.Status.invalid_arguments;
    const name = read(.{ .ptr = value.name.ptr, .len = value.name.len }, true) catch |err| return report(err);
    // Workspace requests distinguish an explicit empty argument from absence.
    // Preserve that intent both for handlers and for the receipt digest.
    const arg: ?[]const u8 = if (value.arg.len == 0)
        (if (value.arg.ptr) |ptr| ptr[0..0] else null)
    else
        read(.{ .ptr = value.arg.ptr, .len = value.arg.len }, false) catch |err| return report(err);
    out.* = runtime.submitOnOwnedStack(value, name.?, arg) catch |err| return report(err);
    return abi.Status.ok;
}

export fn cutrans_vm_grant_external(handle: ?*anyopaque, path: abi.ByteSlice, access: u32, out_grant_id: ?*u64) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const external_path = read(path, true) catch |err| return report(err);
    if (!std.fs.path.isAbsolute(external_path.?)) return abi.Status.invalid_arguments;
    const grant_access: @import("vne").mounts.Access = switch (access) {
        0 => .read_only,
        1 => .read_write,
        else => return abi.Status.invalid_arguments,
    };
    const out = out_grant_id orelse return abi.Status.invalid_arguments;
    const id = runtime.ctx.mounts.grantExternal(allocator, external_path.?, grant_access) catch |err| return report(err);
    out.* = id;
    return abi.Status.ok;
}

export fn cutrans_vm_capability_status(handle: ?*anyopaque, id: abi.ByteSlice) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const capability_id = read(id, true) catch |err| return report(err);
    return switch (@import("capabilities.zig").status(capability_id.?)) {
        .ready => abi.Status.ok,
        .not_ready => abi.Status.not_ready,
        .unsupported => abi.Status.unsupported_capability,
    };
}

export fn cutrans_vm_document_fingerprint(handle: ?*anyopaque, out_fingerprint: ?*u64) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const out = out_fingerprint orelse return abi.Status.invalid_arguments;
    out.* = runtime.ctx.document.fingerprint();
    return abi.Status.ok;
}

export fn cutrans_vm_document_flags(handle: ?*anyopaque, out_flags: ?*u32) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const out = out_flags orelse return abi.Status.invalid_arguments;
    out.* = @as(u32, @intFromBool(runtime.ctx.document.dirty)) | (@as(u32, @intFromBool(runtime.ctx.document.legacy)) << 1);
    return abi.Status.ok;
}

export fn cutrans_vm_document_read(handle: ?*anyopaque, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const required = out_len orelse return abi.Status.invalid_arguments;
    const text = @import("documents.zig").emitAlloc(&runtime.ctx.document, allocator) catch |err| return report(err);
    defer allocator.free(text);
    required.* = text.len;
    const output = buffer orelse return abi.Status.buffer_too_small;
    if (buffer_len < text.len) return abi.Status.buffer_too_small;
    @memcpy(output[0..text.len], text);
    return abi.Status.ok;
}

export fn cutrans_vm_pump(handle: ?*anyopaque) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.pumpOnOwnedStack(false) catch |err| return report(err);
    return abi.Status.ok;
}

/// Shell frames never start or wait for export computation. Scheduling belongs
/// to the explicitly enabled Host (or direct-Shell) driver.
export fn cutrans_vm_frame_pump(handle: ?*anyopaque) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    var task = Runtime.PlaybackTask{ .runtime = runtime };
    runtime.execute(Runtime.PlaybackTask, &task);
    task.result catch |err| return report(err);
    return abi.Status.ok;
}

/// Explicit Host scheduling service; manual/replay instances never self-pump.
export fn cutrans_vm_jobs_pump(handle: ?*anyopaque, out_pending: ?*u32) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    const out = out_pending orelse return abi.Status.invalid_arguments;
    out.* = 0;
    runtime.pumpOnOwnedStack(true) catch |err| {
        out.* = 1; // Preserve retry notification for a pending durable record.
        return report(err);
    };
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    out.* = @intFromBool(document_commands.jobsPending(&runtime.ctx));
    return abi.Status.ok;
}

export fn cutrans_vm_jobs_flush(handle: ?*anyopaque) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    var task = Runtime.FlushTask{ .runtime = runtime };
    runtime.execute(Runtime.FlushTask, &task);
    task.result catch |err| return report(err);
    return abi.Status.ok;
}

export fn cutrans_vm_jobs_read(handle: ?*anyopaque, after_id: u64, buffer: ?[*]u8, capacity: usize, out_len: ?*usize) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    const length = out_len orelse return abi.Status.invalid_arguments;
    length.* = 0;
    const io_value = runtime.io.io();
    runtime.mutex.lockUncancelable(io_value);
    defer runtime.mutex.unlock(io_value);
    var dir = runtime.ctx.paths.openDataDir(io_value, allocator) catch |err| return report(err);
    defer dir.close(io_value);
    const records = @import("job_ledger.zig").page(after_id, 32, allocator, io_value, dir) catch |err| return report(err);
    defer allocator.free(records);
    const View = struct {
        id: u64,
        attempt: u32,
        retry_of: ?u64,
        cancel_requested: bool,
        state: []const u8,
        phase: []const u8,
        origin: workspace.Stamp,
        source_fingerprint: u64,
        document_fingerprint: u64,
        output: []const u8,
        target: []const u8,
        output_sha256: [64]u8,
        output_size: u64,
        error_text: []const u8,
        persistence_pending: bool,
    };
    var items: [32]View = undefined;
    for (records, 0..) |*stored, index| {
        var record = stored;
        const pending = if (runtime.ctx.pending_finalize) |*value| value.task.id == stored.task.id else false;
        if (pending) record = &runtime.ctx.pending_finalize.?;
        items[index] = .{
            .id = record.task.id,
            .attempt = record.job.attempt,
            .retry_of = record.job.retry_of,
            .cancel_requested = record.job.cancel_requested,
            .state = @tagName(record.task.state),
            .phase = @tagName(record.job.phase),
            .origin = record.job.origin,
            .source_fingerprint = record.job.source_fingerprint,
            .document_fingerprint = record.job.document.fingerprint(),
            .output = record.job.path(),
            .target = record.job.target(),
            .output_sha256 = std.fmt.bytesToHex(record.job.output_hash, .lower),
            .output_size = record.job.output_size,
            .error_text = record.job.errorText(),
            .persistence_pending = pending,
        };
    }
    // Old task metadata has no recoverable JobSpec. Keep it visible without
    // inventing an input or reviving a temporary external grant.
    var legacy: @import("tasks.zig").Registry = .{};
    _ = @import("task_journal.zig").loadLegacyArchive(&legacy, allocator, io_value, dir) catch |err| return report(err);
    const LegacyView = struct { id: u64, state: []const u8, has_declaration: bool = false };
    var old_items: [40]LegacyView = undefined;
    var old_count: usize = 0;
    for (legacy.items[0..legacy.count]) |task| {
        if (task.id <= after_id) continue;
        const known = @import("job_ledger.zig").load(task.id, allocator, io_value, dir) catch |err| return report(err);
        if (known != null) continue;
        old_items[old_count] = .{ .id = task.id, .state = @tagName(task.state) };
        old_count += 1;
    }
    const text = std.json.Stringify.valueAlloc(allocator, .{
        .format = "cutrans-jobs-page/1",
        .after = after_id,
        .next_after = if (records.len == 0) after_id else records[records.len - 1].task.id,
        .active_count = runtime.ctx.export_count + @as(usize, @intFromBool(runtime.ctx.active_export != null)),
        .record_pending = runtime.ctx.pending_finalize != null,
        .recent_count = runtime.ctx.tasks.count,
        .legacy_archive = @import("task_journal.zig").legacy_archive_path,
        .legacy_items = old_items[0..old_count],
        .items = items[0..records.len],
    }, .{}) catch |err| return report(err);
    defer allocator.free(text);
    length.* = text.len;
    const output = buffer orelse return abi.Status.buffer_too_small;
    if (capacity < text.len) return abi.Status.buffer_too_small;
    @memcpy(output[0..text.len], text);
    return abi.Status.ok;
}

export fn cutrans_vm_input_push(handle: ?*anyopaque, input: ?*const abi.InputEvent, out_serial: ?*u64) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const value = input orelse return abi.Status.invalid_arguments;
    if (value.struct_size < @sizeOf(abi.InputEvent) or value.abi_version != abi.version) return abi.Status.abi_mismatch;
    if (!std.mem.eql(u8, &value.reserved, &[_]u8{ 0, 0, 0 })) return abi.Status.invalid_arguments;
    const text = read(value.text, false) catch |err| return report(err);
    if (text) |bytes| if (bytes.len > 64) return abi.Status.invalid_arguments;
    const serial = std.math.add(u64, runtime.ctx.devices.input.last_serial, 1) catch return abi.Status.failed;
    var event = @import("vne").input.Event{
        .serial = serial,
        .time_ns = runtime.ctx.clock.now() catch |err| return report(err),
        .kind = std.enums.fromInt(@import("vne").input.Kind, value.kind) orelse return abi.Status.invalid_arguments,
        .action = std.enums.fromInt(@import("vne").input.Action, value.action) orelse return abi.Status.invalid_arguments,
        .code = value.code,
        .mods = value.mods,
        .context = value.context,
        .x = value.x,
        .y = value.y,
    };
    if (text) |bytes| {
        @memcpy(event.text[0..bytes.len], bytes);
        event.text_len = @intCast(bytes.len);
    }
    event.validate() catch return abi.Status.invalid_arguments;
    runtime.input_recording.consume(&runtime.ctx, event) catch |err| return report(err);
    if (out_serial) |out| out.* = serial;
    return abi.Status.ok;
}

export fn cutrans_vm_input_flush(handle: ?*anyopaque) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    runtime.input_recording.flush() catch |err| return report(err);
    return abi.Status.ok;
}

export fn cutrans_vm_input_begin(handle: ?*anyopaque, path: abi.ByteSlice) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const record_path = read(path, true) catch |err| return report(err);
    runtime.input_recording.start(&runtime.ctx, record_path.?) catch |err| return report(err);
    return abi.Status.ok;
}

export fn cutrans_vm_input_end(handle: ?*anyopaque, out_report: ?*abi.InputRecordReport) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const report_value = runtime.input_recording.finish() catch |err| return report(err);
    if (out_report) |out| out.* = report_value;
    return abi.Status.ok;
}

export fn cutrans_vm_playback_report(handle: ?*anyopaque, out_report: ?*abi.PlaybackReport) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const out = out_report orelse return abi.Status.invalid_arguments;
    out.* = runtime.ctx.playback.report(&runtime.ctx);
    return abi.Status.ok;
}

export fn cutrans_vm_library_list(handle: ?*anyopaque, out_report: ?*abi.LibraryListReport) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const out = out_report orelse return abi.Status.invalid_arguments;
    out.* = std.mem.zeroes(abi.LibraryListReport);
    out.struct_size = @sizeOf(abi.LibraryListReport);
    out.abi_version = abi.version;
    out.revision = runtime.ctx.library.revision;
    out.count = @intCast(runtime.ctx.library.folder_count + runtime.ctx.library.count);
    var output_index: usize = 0;
    for (runtime.ctx.library.folders[0..runtime.ctx.library.folder_count]) |folder| {
        out.entries[output_index] = .{
            .struct_size = @sizeOf(abi.LibraryEntry),
            .abi_version = abi.version,
            .id = folder.id,
            .parent_id = folder.parent_id,
            .node_kind = 1,
        };
        output_index += 1;
    }
    for (runtime.ctx.library.items[0..runtime.ctx.library.count]) |item| {
        out.entries[output_index] = .{
            .struct_size = @sizeOf(abi.LibraryEntry),
            .abi_version = abi.version,
            .id = item.id,
            .parent_id = item.parent_id,
            .node_kind = 2,
            .kind = if (item.kind == .reference) 1 else 2,
            .provenance = @backingInt(item.provenance),
            .content_hash = item.content_hash,
        };
        output_index += 1;
    }
    return abi.Status.ok;
}

export fn cutrans_vm_library_label(handle: ?*anyopaque, id: u64, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const label = runtime.ctx.library.nodeLabel(id) orelse return abi.Status.not_found;
    return copyBytes(label, buffer, buffer_len, out_len);
}

export fn cutrans_vm_asset_list(handle: ?*anyopaque, out_report: ?*abi.AssetListReport) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const out = out_report orelse return abi.Status.invalid_arguments;
    out.* = std.mem.zeroes(abi.AssetListReport);
    out.struct_size = @sizeOf(abi.AssetListReport);
    out.abi_version = abi.version;
    out.revision = runtime.ctx.assets.revision;
    out.count = @intCast(runtime.ctx.assets.count);
    for (runtime.ctx.assets.items[0..runtime.ctx.assets.count], 0..) |asset, index| {
        const metadata: struct { kind: u32 = 0, id: u64 = 0 } = if (asset.source.identity) |identity| switch (identity) {
            .library => |id| if (runtime.ctx.library.get(id)) |resource| .{
                .kind = if (resource.kind == .reference) 1 else 2,
                .id = id,
            } else .{},
            else => .{},
        } else .{};
        out.entries[index] = .{
            .handle = asset.handle,
            .byte_length = asset.bytes.len,
            .leases = asset.leases,
            .source_kind = @backingInt(asset.source.kind),
            .library_kind = metadata.kind,
            .library_id = metadata.id,
            .content_hash = asset.source.content_hash,
            .source_status = @backingInt(@import("assets.zig").Workspace.visibleSourceStatus(&runtime.ctx, &asset)),
        };
    }
    return abi.Status.ok;
}

fn copyBytes(bytes: []const u8, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) i32 {
    const required = out_len orelse return abi.Status.invalid_arguments;
    required.* = bytes.len;
    const output = buffer orelse return abi.Status.buffer_too_small;
    if (buffer_len < bytes.len) return abi.Status.buffer_too_small;
    @memcpy(output[0..bytes.len], bytes);
    return abi.Status.ok;
}

export fn cutrans_vm_asset_source(handle: ?*anyopaque, asset_id: u64, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const asset = runtime.ctx.assets.get(asset_id) catch |err| return report(err);
    return copyBytes(asset.source.uri, buffer, buffer_len, out_len);
}

export fn cutrans_vm_asset_read(handle: ?*anyopaque, asset_id: u64, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const asset = runtime.ctx.assets.get(asset_id) catch |err| return report(err);
    return copyBytes(asset.bytes, buffer, buffer_len, out_len);
}

export fn cutrans_vm_asset_preview(handle: ?*anyopaque, asset_id: u64, out_info: ?*abi.AssetInfo) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const out = out_info orelse return abi.Status.invalid_arguments;
    const preview = runtime.ctx.assets.preview(asset_id) catch |err| return report(err);
    const asset = runtime.ctx.assets.get(asset_id) catch |err| return report(err);
    out.* = .{
        .struct_size = @sizeOf(abi.AssetInfo),
        .abi_version = abi.version,
        .handle = asset.handle,
        .byte_length = asset.bytes.len,
        .content_hash = asset.source.content_hash,
        .width = preview.width,
        .height = preview.height,
        .media_kind = 1,
        .coverage = 1,
    };
    return abi.Status.ok;
}

export fn cutrans_vm_asset_open_external(handle: ?*anyopaque, path: abi.ByteSlice, out_asset_id: ?*u64) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const external_path = read(path, true) catch |err| return report(err);
    if (!std.fs.path.isAbsolute(external_path.?)) return abi.Status.invalid_arguments;
    const out = out_asset_id orelse return abi.Status.invalid_arguments;
    const grant = runtime.ctx.library.importExternal(&runtime.ctx, external_path.?) catch |err| return report(err);
    var uri_buffer: [64]u8 = undefined;
    const uri = std.fmt.bufPrint(&uri_buffer, "library://{d}", .{grant}) catch return abi.Status.failed;
    const asset_id = runtime.ctx.assets.open(&runtime.ctx, uri) catch |err| return report(err);
    out.* = asset_id;
    return abi.Status.accepted;
}

fn sourceExpectedHash(value: abi.ByteSlice) !?[32]u8 {
    if (value.len == 0) return null;
    if (value.len != 64) return error.InvalidSourceHash;
    const pointer = value.ptr orelse return error.InvalidSourceHash;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, pointer[0..64]) catch return error.InvalidSourceHash;
    return digest;
}

export fn cutrans_vm_source_read(handle: ?*anyopaque, uri: abi.ByteSlice, expected_sha256: abi.ByteSlice, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) callconv(.c) i32 {
    const out = out_len orelse return abi.Status.invalid_arguments;
    out.* = 0;
    const runtime = from(handle) catch |err| return report(err);
    const source = read(uri, true) catch return abi.Status.invalid_arguments;
    if (std.mem.indexOfScalar(u8, source.?, 0) != null) return abi.Status.invalid_arguments;
    const expected = sourceExpectedHash(expected_sha256) catch return abi.Status.invalid_arguments;
    var task = Runtime.ReadSourceTask{ .runtime = runtime, .uri = source.?, .expected = expected, .buffer = buffer, .capacity = buffer_len, .length = out };
    runtime.execute(Runtime.ReadSourceTask, &task);
    return task.result;
}

test "source reading validates complete hashes and clears failed output lengths" {
    try std.testing.expect((try sourceExpectedHash(.{})) == null);
    const text = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expect((try sourceExpectedHash(slice(text))) != null);
    try std.testing.expectError(error.InvalidSourceHash, sourceExpectedHash(slice(text[0..63])));
    try std.testing.expectError(error.InvalidSourceHash, sourceExpectedHash(.{ .len = 64 }));
    try std.testing.expectError(error.InvalidSourceHash, sourceExpectedHash(slice("g123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")));
    var length: usize = 999;
    try std.testing.expectEqual(abi.Status.invalid_handle, cutrans_vm_source_read(null, slice("library://9"), .{}, null, 0, &length));
    try std.testing.expectEqual(@as(usize, 0), length);
    try std.testing.expectEqual(abi.Status.invalid_arguments, cutrans_vm_source_read(null, slice("library://9"), .{}, null, 0, null));
}

export fn cutrans_vm_frame_report(handle: ?*anyopaque, frame_report: ?*const abi.FrameReport) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const value = frame_report orelse return abi.Status.invalid_arguments;
    if (value.struct_size < @sizeOf(abi.FrameReport) or value.abi_version != abi.version) return abi.Status.abi_mismatch;
    if (value.reserved != 0 or value.t < -1) return abi.Status.invalid_arguments;
    const kind = std.enums.fromInt(@import("vne").frame.ReportKind, value.kind) orelse return abi.Status.invalid_arguments;
    switch (kind) {
        .submitted => {
            if (value.generation == 0) return abi.Status.invalid_arguments;
            if (value.content_id != runtime.ctx.document.fingerprint()) return report(error.FrameContentMismatch);
            runtime.ctx.devices.frame_sink.markSubmitted(value.content_id, value.generation, value.t);
            if (value.t >= 0 and runtime.last_playback_log_t != value.t) {
                const playback = runtime.ctx.playback.report(&runtime.ctx);
                std.debug.print("CUTRANS_PLAYBACK_SUBMIT_OK t={d} cursor={d}\n", .{ value.t, playback.cursor });
                runtime.last_playback_log_t = value.t;
            }
            if (runtime.ctx.devices.frame_sink.present_count == 1) {
                std.debug.print("CUTRANS_FRAME_PRESENT_OK generation={d} content={d} feedback=submitted\n", .{ value.generation, value.content_id });
            }
        },
        .underflow => {
            if (value.t < 0 or value.content_id != 0 or value.generation != 0) return abi.Status.invalid_arguments;
            runtime.ctx.devices.frame_sink.underflow(value.t);
        },
        .unavailable => {
            if (value.content_id != 0 or value.generation != 0) return abi.Status.invalid_arguments;
            runtime.ctx.devices.frame_sink.unavailable(value.t);
        },
    }
    return abi.Status.ok;
}

export fn cutrans_vm_replay(handle: ?*anyopaque, path: abi.ByteSlice, out_report: ?*abi.ReplayReport) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    runtime.mutex.lockUncancelable(runtime.io.io());
    defer runtime.mutex.unlock(runtime.io.io());
    const replay_path = read(path, true) catch |err| return report(err);
    const out = out_report orelse return abi.Status.invalid_arguments;
    const report_value = @import("replay.zig").runUri(&runtime.ctx, replay_path.?) catch |err| return report(err);
    out.* = .{
        .struct_size = @sizeOf(abi.ReplayReport),
        .abi_version = abi.version,
        .kind = report_value.kind,
        .input_events = report_value.input_events,
        .document_fingerprint = report_value.document_fingerprint,
        .history_count = report_value.history_count,
        .history_cursor = report_value.history_cursor,
        .task_count = report_value.task_count,
        .tasks_hash = report_value.tasks_hash,
        .time_ns = report_value.time_ns,
        .event_count = report_value.event_count,
    };
    return abi.Status.ok;
}

fn slice(value: []const u8) abi.ByteSlice {
    return .{ .ptr = value.ptr, .len = value.len };
}

export fn cutrans_vm_start_shell(handle: ?*anyopaque, request: ?*const abi.ShellRequest) callconv(.c) i32 {
    const runtime = from(handle) catch |err| return report(err);
    const value = request orelse return abi.Status.invalid_arguments;
    if (value.struct_size < @sizeOf(abi.ShellRequest) or value.abi_version != abi.version) return abi.Status.abi_mismatch;
    if (value.playback_frames < 0 or value.playback_frames > 600 or value.asset_workspace > 1) return abi.Status.invalid_arguments;
    const resource = read(value.resource_dir, true) catch |err| return report(err);
    const open_path = read(value.open_path, false) catch |err| return report(err);
    const record_path = read(value.record_input, false) catch |err| return report(err);
    if (!std.fs.path.isAbsolute(resource.?)) return abi.Status.invalid_arguments;
    const io = runtime.io.io();
    var shell_dir = std.Io.Dir.openDirAbsolute(io, resource.?, .{}) catch |err| return report(err);
    defer shell_dir.close(io);
    const parsed = @import("vne").runtime_pack.verifyShellFile(allocator, io, shell_dir) catch |err| return report(err);
    defer parsed.deinit();
    for (parsed.value.required_capabilities) |id| {
        if (@import("capabilities.zig").status(id) != .ready) return abi.Status.unsupported_capability;
    }
    {
        runtime.mutex.lockUncancelable(io);
        defer runtime.mutex.unlock(io);
        if (open_path) |path| {
            if (!std.fs.path.isAbsolute(path)) return abi.Status.invalid_arguments;
            const grant_id = runtime.ctx.mounts.grantExternal(allocator, path, .read_write) catch |err| return report(err);
            var uri_buffer: [64]u8 = undefined;
            const uri = std.fmt.bufPrint(&uri_buffer, "external://{d}", .{grant_id}) catch return abi.Status.failed;
            const result = runtime.ctx.command.dispatch(.{ .name = "doc.open", .arg = uri });
            if (result.code != .ok) return commandCode(result.code);
        }
        if (record_path) |path| runtime.input_recording.start(&runtime.ctx, path) catch |err| return report(err);
    }
    const entry_path = std.fs.path.join(allocator, &.{ resource.?, parsed.value.entry }) catch |err| return report(err);
    defer allocator.free(entry_path);
    var library = @import("ports").library.Library.open(allocator, entry_path) catch |err| return report(err);
    defer library.close();
    const entry = library.lookup(abi.ShellEntry, "cutrans_shell_run") orelse return abi.Status.not_found;
    const config = abi.ShellConfig{
        .struct_size = @sizeOf(abi.ShellConfig),
        .abi_version = abi.version,
        .mode = abi.modeToInt(runtime.ctx.paths.mode),
        .resource_dir = value.resource_dir,
        .data_dir = slice(runtime.ctx.paths.data_dir),
        .open_path = value.open_path,
        .playback_frames = value.playback_frames,
        .asset_workspace = value.asset_workspace,
    };
    const shell_api = abi.ShellApi{
        .struct_size = @sizeOf(abi.ShellApi),
        .abi_version = abi.version,
        .context = runtime,
        .command_result = cutrans_vm_command_result,
        .document_fingerprint = cutrans_vm_document_fingerprint,
        .document_flags = cutrans_vm_document_flags,
        .document_read = cutrans_vm_document_read,
        .pump = cutrans_vm_frame_pump,
        .input_push = cutrans_vm_input_push,
        .input_flush = cutrans_vm_input_flush,
        .frame_report = cutrans_vm_frame_report,
        .playback_report = cutrans_vm_playback_report,
        .library_list = cutrans_vm_library_list,
        .library_label = cutrans_vm_library_label,
        .asset_list = cutrans_vm_asset_list,
        .asset_source = cutrans_vm_asset_source,
        .asset_preview = cutrans_vm_asset_preview,
        .asset_read = cutrans_vm_asset_read,
        .asset_open_external = cutrans_vm_asset_open_external,
        .workspace_api = cutrans_vm_workspace_api,
        .source_read = cutrans_vm_source_read,
        .resource_api = cutrans_vm_resource_api,
    };
    var direct_jobs: @import("vne").job_driver.Driver = undefined;
    {
        runtime.mutex.lockUncancelable(io);
        defer runtime.mutex.unlock(io);
        if (runtime.shell_driver != null) return abi.Status.invalid_state;
        direct_jobs.start(io, runtime, cutrans_vm_jobs_pump) catch |err| return report(err);
        runtime.shell_driver = &direct_jobs;
    }
    defer {
        direct_jobs.pauseAndWait();
        runtime.mutex.lockUncancelable(io);
        runtime.shell_driver = null;
        runtime.mutex.unlock(io);
        direct_jobs.deinit();
    }
    const status = entry(&config, &shell_api);
    // A direct Shell owns this VM lifetime. As with Host stop, do not report
    // clean completion while a known output outcome exists only in memory.
    direct_jobs.pauseAndWait();
    const jobs_status = cutrans_vm_jobs_flush(runtime);
    runtime.mutex.lockUncancelable(io);
    defer runtime.mutex.unlock(io);
    if (runtime.input_recording.enabled) {
        const report_value = runtime.input_recording.finish() catch |err| return report(err);
        if (report_value.event_count > 0) std.debug.print("CUTRANS_INPUT_RECORD_OK events={d} time_ns={d}\n", .{ report_value.event_count, report_value.time_ns });
    }
    return if (jobs_status == abi.Status.ok) status else jobs_status;
}

fn testRuntime(dir: std.Io.Dir) !*Runtime {
    const root = try dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, resource);
    return Runtime.createOnOwnedStack(.{ .struct_size = @sizeOf(abi.Config), .abi_version = abi.version, .mode = 1, .resource_dir = slice(resource), .data_dir = slice(data) });
}

fn testWait(event: *std.Io.Event) !void {
    try event.waitTimeout(std.testing.io, .{ .deadline = .fromNow(std.testing.io, .{ .raw = .{ .nanoseconds = 3 * std.time.ns_per_s }, .clock = .awake }) });
}

test "blocked export computation does not own session or GUI pump and cancellation is durable" {
    const Barrier = struct {
        entered: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        fn observe(pointer: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.entered.set(std.testing.io);
            self.release.waitUncancelable(std.testing.io);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try testRuntime(tmp.dir);
    defer runtime.destroy();
    runtime.ctx.document.width = 7;
    runtime.ctx.document.height = 5;
    var barrier: Barrier = .{};
    runtime.before_compute = Barrier.observe;
    runtime.compute_observer = &barrier;
    var id: u64 = 0;
    try std.testing.expectEqual(abi.Status.accepted, cutrans_vm_command_result(runtime, slice("editor.export.png"), slice("session://exports/cancelled.png"), &id));
    // An idle Shell frame must not steal a queued job and wait on its compute.
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_frame_pump(runtime));
    try std.testing.expect(!barrier.entered.isSet());
    const Pump = struct {
        runtime: *Runtime,
        done: std.Io.Event = .unset,
        status: i32 = -1,
        fn run(self: *@This()) void {
            var pending: u32 = 0;
            self.status = cutrans_vm_jobs_pump(self.runtime, &pending);
            self.done.set(std.testing.io);
        }
    };
    var pumping = Pump{ .runtime = runtime };
    const thread = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, Pump.run, .{&pumping});
    defer {
        barrier.release.set(std.testing.io);
        thread.join();
    }
    try testWait(&barrier.entered);
    const Actions = struct {
        runtime: *Runtime,
        done: std.Io.Event = .unset,
        statuses: [4]i32 = @splat(-1),
        fn run(self: *@This()) void {
            self.statuses[0] = cutrans_vm_command(self.runtime, slice("editor.gain.set"), slice("c1 0.25"));
            self.statuses[1] = cutrans_vm_command(self.runtime, slice("task.cancel"), slice("1"));
            self.statuses[2] = cutrans_vm_frame_pump(self.runtime);
            self.statuses[3] = cutrans_vm_pump(self.runtime);
            self.done.set(std.testing.io);
        }
    };
    var actions = Actions{ .runtime = runtime };
    const actions_thread = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, Actions.run, .{&actions});
    defer {
        barrier.release.set(std.testing.io);
        actions_thread.join();
    }
    // This deadline proves completion while compute remains deliberately held.
    try testWait(&actions.done);
    for (actions.statuses) |status| try std.testing.expectEqual(abi.Status.ok, status);
    try std.testing.expect(!pumping.done.isSet());
    var dir = try runtime.ctx.paths.openDataDir(std.testing.io, std.testing.allocator);
    defer dir.close(std.testing.io);
    const requested = (try @import("job_ledger.zig").load(id, std.testing.allocator, std.testing.io, dir)).?;
    try std.testing.expect(requested.job.cancel_requested);
    try std.testing.expectEqual(@import("tasks.zig").State.running, requested.task.state);
    barrier.release.set(std.testing.io);
    try testWait(&pumping.done);
    try std.testing.expectEqual(abi.Status.ok, pumping.status);
    const cancelled = (try @import("job_ledger.zig").load(id, std.testing.allocator, std.testing.io, dir)).?;
    try std.testing.expectEqual(@import("tasks.zig").State.cancelled, cancelled.task.state);
    try std.testing.expectError(error.FileNotFound, dir.openFile(std.testing.io, "exports/cancelled.png", .{}));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(runtime, slice("task.cancel"), slice("1")));
    runtime.before_compute = null;
    runtime.compute_observer = null;
    const name = "task.retry";
    const arg = "1 session://exports/retried.png";
    const request = workspace.Request{ .client_hi = 1, .client_lo = 2, .sequence = 1, .expected = document_requests.Registry.stamp(&runtime.ctx, runtime.epoch), .name = .{ .ptr = name.ptr, .len = name.len }, .arg = .{ .ptr = arg.ptr, .len = arg.len } };
    var first: workspace.Outcome = undefined;
    var again: workspace.Outcome = undefined;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_document_submit(runtime, &request, &first));
    try std.testing.expectEqual(abi.Status.accepted, first.status);
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_document_submit(runtime, &request, &again));
    try std.testing.expectEqual(first.task_id, again.task_id);
    try std.testing.expectEqual(@as(u32, @backingInt(workspace.Disposition.replayed)), again.disposition);
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_pump(runtime));
    const retried = (try @import("job_ledger.zig").load(first.task_id, std.testing.allocator, std.testing.io, dir)).?;
    try std.testing.expectEqual(@as(u32, 2), retried.job.attempt);
    try std.testing.expectEqual(@as(?u64, 1), retried.job.retry_of);
    try std.testing.expectEqual(@as(f32, 0.8), retried.job.document.nodes[1].value);
    var output = try @import("image.zig").load(std.testing.allocator, std.testing.io, dir, "exports/retried.png");
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 26), output.pixels[0]);
    try std.testing.expectEqual(abi.Status.invalid_state, cutrans_vm_command(runtime, slice("task.cancel"), slice("2")));
}

test "external retry rejects a reused grant target until explicitly retargeted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const target_a = try std.fs.path.join(std.testing.allocator, &.{ root, "external-a.png" });
    defer std.testing.allocator.free(target_a);
    const target_b = try std.fs.path.join(std.testing.allocator, &.{ root, "external-b.png" });
    defer std.testing.allocator.free(target_b);
    const first = try testRuntime(tmp.dir);
    {
        defer first.destroy();
        first.ctx.document.width = 2;
        first.ctx.document.height = 2;
        var grant: u64 = 0;
        try std.testing.expectEqual(abi.Status.ok, cutrans_vm_grant_external(first, slice(target_a), 1, &grant));
        try std.testing.expectEqual(@as(u64, 1), grant);
        try std.testing.expectEqual(abi.Status.accepted, cutrans_vm_command(first, slice("editor.export.png"), slice("external://1")));
        try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(first, slice("task.cancel"), slice("1")));
    }
    const second = try testRuntime(tmp.dir);
    defer second.destroy();
    var reused: u64 = 0;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_grant_external(second, slice(target_b), 1, &reused));
    try std.testing.expectEqual(@as(u64, 1), reused);
    try std.testing.expectEqual(abi.Status.invalid_arguments, cutrans_vm_command(second, slice("task.retry"), slice("1")));
    try std.testing.expectEqual(abi.Status.invalid_arguments, cutrans_vm_command(second, slice("task.retry"), slice("1 external://1")));
    try std.testing.expectEqual(@as(u64, 1), second.ctx.tasks.task_clock);
    try std.testing.expectEqual(abi.Status.accepted, cutrans_vm_command(second, slice("task.retry"), slice("1 --retarget external://1")));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_pump(second));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "external-a.png", .{}));
    var output = try tmp.dir.openFile(std.testing.io, "external-b.png", .{});
    output.close(std.testing.io);
    var dir = try second.ctx.paths.openDataDir(std.testing.io, std.testing.allocator);
    defer dir.close(std.testing.io);
    const parent = (try @import("job_ledger.zig").load(1, std.testing.allocator, std.testing.io, dir)).?;
    const child = (try @import("job_ledger.zig").load(2, std.testing.allocator, std.testing.io, dir)).?;
    try std.testing.expectEqual(@import("tasks.zig").State.cancelled, parent.task.state);
    try std.testing.expectEqual(@as(u32, 2), child.job.attempt);
    try std.testing.expectEqualStrings(target_b, child.job.target());
}

test "native ABI drives a real document and restores it in another runtime" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    const examples = try std.fs.path.join(std.testing.allocator, &.{ resource, "assets/examples" });
    defer std.testing.allocator.free(examples);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, examples);
    const minimal = try std.fs.path.join(std.testing.allocator, &.{ examples, "minimal.cut" });
    defer std.testing.allocator.free(minimal);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = minimal, .data = @import("assets").minimal_cut });
    var config = abi.Config{
        .struct_size = @sizeOf(abi.Config),
        .abi_version = abi.version,
        .mode = 1,
        .resource_dir = slice(resource),
        .data_dir = slice(data),
    };
    var incompatible = config;
    incompatible.abi_version = abi.version + 1;
    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(abi.Status.abi_mismatch, cutrans_vm_create(&incompatible, &handle));
    try std.testing.expectEqual(@as(?*anyopaque, null), handle);
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_create(&config, &handle));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_capability_status(handle, slice("node.testsrc")));
    try std.testing.expectEqual(abi.Status.unsupported_capability, cutrans_vm_capability_status(handle, slice("node.missing")));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(handle, slice("doc.open"), .{}));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(handle, slice("editor.gain.set"), slice("c1 0.25")));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(handle, slice("history.undo"), .{}));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(handle, slice("history.redo"), .{}));
    try std.testing.expectEqual(abi.Status.invalid_arguments, cutrans_vm_command(handle, slice("doc.open"), slice(minimal)));
    var grant_id: u64 = 0;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_grant_external(handle, slice(minimal), 1, &grant_id));
    var uri_buffer: [64]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buffer, "external://{d}", .{grant_id});
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(handle, slice("doc.open"), slice(uri)));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(handle, slice("editor.gain.set"), slice("c1 0.25")));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(handle, slice("doc.save"), slice(uri)));
    try std.testing.expectEqual(abi.Status.invalid_arguments, cutrans_vm_command(handle, slice("doc.save"), slice("pack://assets/examples/minimal.cut")));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(handle, slice("doc.save"), .{}));
    var flags: u32 = 0;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_document_flags(handle, &flags));
    try std.testing.expectEqual(@as(u32, 0), flags);
    var text_len: usize = 0;
    try std.testing.expectEqual(abi.Status.buffer_too_small, cutrans_vm_document_read(handle, null, 0, &text_len));
    const text = try std.testing.allocator.alloc(u8, text_len);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_document_read(handle, text.ptr, text.len, &text_len));
    try std.testing.expect(std.mem.indexOf(u8, text, "value:0.25") != null);
    var task_id: u64 = 0;
    try std.testing.expectEqual(abi.Status.accepted, cutrans_vm_command_result(handle, slice("editor.export.png"), slice("session://exports/vne.png"), &task_id));
    try std.testing.expect(task_id != 0);
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_pump(handle));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_pump(handle));
    var fingerprint: u64 = 0;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_document_fingerprint(handle, &fingerprint));
    cutrans_vm_destroy(handle);
    handle = null;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_create(&config, &handle));
    defer cutrans_vm_destroy(handle);
    var restored: u64 = 0;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_document_fingerprint(handle, &restored));
    try std.testing.expectEqual(fingerprint, restored);
    try std.testing.expectEqual(abi.Status.unknown_command, cutrans_vm_command(handle, slice("missing.command"), .{}));
    try std.testing.expectEqual(abi.Status.invalid_handle, cutrans_vm_document_fingerprint(null, &restored));
}

test "native ABI consumes and records semantic input for a fresh replay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    const config = abi.Config{
        .struct_size = @sizeOf(abi.Config),
        .abi_version = abi.version,
        .mode = 1,
        .resource_dir = slice(resource),
        .data_dir = slice(data),
    };
    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_create(&config, &handle));
    try std.testing.expectEqual(abi.Status.failed, cutrans_vm_input_begin(handle, slice("pack://input/forbidden.cvr")));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_input_begin(handle, slice("session://input/native.cvr")));
    var invalid = abi.InputEvent{
        .struct_size = @sizeOf(abi.InputEvent),
        .abi_version = abi.version,
        .kind = 255,
        .action = 0,
        .code = 0,
        .mods = 0,
    };
    try std.testing.expectEqual(abi.Status.invalid_arguments, cutrans_vm_input_push(handle, &invalid, null));
    for (0..40) |index| {
        const event = abi.InputEvent{
            .struct_size = @sizeOf(abi.InputEvent),
            .abi_version = abi.version,
            .kind = @backingInt(@import("vne").input.Kind.pointer_move),
            .action = @backingInt(@import("vne").input.Action.none),
            .code = 0,
            .mods = 0,
            .x = @intCast(index),
            .y = 24,
        };
        var serial: u64 = 0;
        try std.testing.expectEqual(abi.Status.ok, cutrans_vm_input_push(handle, &event, &serial));
        try std.testing.expectEqual(@as(u64, @intCast(index + 1)), serial);
    }
    const key = abi.InputEvent{
        .struct_size = @sizeOf(abi.InputEvent),
        .abi_version = abi.version,
        .kind = @backingInt(@import("vne").input.Kind.key_down),
        .action = @backingInt(@import("vne").input.Action.repeat),
        .code = 257,
        .mods = 3,
    };
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_input_push(handle, &key, null));
    const sample = "你\n好,Cutrans";
    const text = abi.InputEvent{
        .struct_size = @sizeOf(abi.InputEvent),
        .abi_version = abi.version,
        .kind = @backingInt(@import("vne").input.Kind.text),
        .action = @backingInt(@import("vne").input.Action.none),
        .code = 0,
        .mods = 0,
        .text = slice(sample),
    };
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_input_push(handle, &text, null));
    const focus = abi.InputEvent{
        .struct_size = @sizeOf(abi.InputEvent),
        .abi_version = abi.version,
        .kind = @backingInt(@import("vne").input.Kind.focus),
        .action = @backingInt(@import("vne").input.Action.none),
        .code = 0,
        .mods = 0,
        .x = 1,
    };
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_input_push(handle, &focus, null));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_input_flush(handle));
    const runtime = try from(handle);
    try std.testing.expectEqual(@as(usize, 0), runtime.ctx.devices.input.count);
    try std.testing.expectEqual(@as(u64, 43), runtime.ctx.devices.input.consumed_count);
    var record: abi.InputRecordReport = undefined;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_input_end(handle, &record));
    try std.testing.expectEqual(@as(u64, 43), record.event_count);
    cutrans_vm_destroy(handle);
    handle = null;
    const log_path = try std.fs.path.join(std.testing.allocator, &.{ data, "input/native.cvr" });
    defer std.testing.allocator.free(log_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, log_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "cutrans_input_replay=3\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, root) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, sample) == null);
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_create(&config, &handle));
    defer cutrans_vm_destroy(handle);
    var replayed: abi.ReplayReport = undefined;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_replay(handle, slice("session://input/native.cvr"), &replayed));
    try std.testing.expectEqual(@as(u64, 43), replayed.input_events);
    try std.testing.expectEqual(record.time_ns, replayed.time_ns);
    try std.testing.expectEqual(@as(u64, 43), (try from(handle)).ctx.devices.input.consumed_count);
    try std.testing.expectEqual(abi.Status.failed, cutrans_vm_replay(handle, slice("session://input/native.cvr"), &replayed));
}

test "native frame reports confirm current content and separate output failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    const config = abi.Config{
        .struct_size = @sizeOf(abi.Config),
        .abi_version = abi.version,
        .mode = 1,
        .resource_dir = slice(resource),
        .data_dir = slice(data),
    };
    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_create(&config, &handle));
    defer cutrans_vm_destroy(handle);
    const runtime = try from(handle);
    var frame_report = abi.FrameReport{
        .struct_size = @sizeOf(abi.FrameReport),
        .abi_version = abi.version,
        .content_id = runtime.ctx.document.fingerprint(),
        .generation = 1,
        .t = -1,
        .kind = @backingInt(@import("vne").frame.ReportKind.submitted),
    };
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_frame_report(handle, &frame_report));
    try std.testing.expectEqual(@as(u64, 1), runtime.ctx.devices.frame_sink.present_count);
    try std.testing.expectEqual(@as(u64, 0), runtime.ctx.devices.frame_sink.offer_count);
    try std.testing.expectEqual(frame_report.content_id, runtime.ctx.devices.frame_sink.last_presented_content_id);
    frame_report.content_id ^= 1;
    try std.testing.expectEqual(abi.Status.failed, cutrans_vm_frame_report(handle, &frame_report));
    try std.testing.expectEqual(@as(u64, 1), runtime.ctx.devices.frame_sink.present_count);
    frame_report = .{
        .struct_size = @sizeOf(abi.FrameReport),
        .abi_version = abi.version,
        .content_id = 0,
        .generation = 0,
        .t = 0,
        .kind = @backingInt(@import("vne").frame.ReportKind.underflow),
    };
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_frame_report(handle, &frame_report));
    try std.testing.expectEqual(@as(u64, 1), runtime.ctx.devices.frame_sink.underflow_count);
    try std.testing.expectEqual(@as(i64, 0), runtime.ctx.devices.frame_sink.last_underflow_t);
    frame_report.kind = @backingInt(@import("vne").frame.ReportKind.unavailable);
    frame_report.t = -1;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_frame_report(handle, &frame_report));
    try std.testing.expectEqual(@as(u64, 1), runtime.ctx.devices.frame_sink.unavailable_count);
    frame_report.kind = 255;
    try std.testing.expectEqual(abi.Status.invalid_arguments, cutrans_vm_frame_report(handle, &frame_report));
}

test "Pack asset insertion restores a Source document without the Station" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ resource, "assets/examples/source.png" });
    defer std.testing.allocator.free(source_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(source_path).?);
    var pixels = [_]u8{ 1, 2, 3, 255 };
    try @import("image.zig").savePngExternal(std.testing.allocator, std.testing.io, source_path, .{ .width = 1, .height = 1, .pixels = &pixels });
    const config = abi.Config{
        .struct_size = @sizeOf(abi.Config),
        .abi_version = abi.version,
        .mode = 1,
        .resource_dir = slice(resource),
        .data_dir = slice(data),
    };
    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_create(&config, &handle));
    try std.testing.expectEqual(abi.Status.accepted, cutrans_vm_command(handle, slice("asset.open"), slice("pack://assets/examples/source.png")));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(handle, slice("editor.asset.insert"), slice("1")));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(handle, slice("history.undo"), .{}));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(handle, slice("history.redo"), .{}));
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_command(handle, slice("doc.save"), .{}));
    cutrans_vm_destroy(handle);
    handle = null;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_create(&config, &handle));
    defer cutrans_vm_destroy(handle);
    var listing: abi.AssetListReport = undefined;
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_asset_list(handle, &listing));
    try std.testing.expectEqual(@as(u32, 0), listing.count);
    var required: usize = 0;
    try std.testing.expectEqual(abi.Status.buffer_too_small, cutrans_vm_document_read(handle, null, 0, &required));
    const text = try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(abi.Status.ok, cutrans_vm_document_read(handle, text.ptr, text.len, &required));
    try std.testing.expect(std.mem.indexOf(u8, text, "pack://assets/examples/source.png") != null);
}
