//! instance.zig — 单进程虚拟环境实例
//!
//! 2026-11-12 起 Cutrans 只有一种运行形态：一个进程同时持有环境核心（Runtime、
//! 作业驱动线程、生命周期记录）和 App。本文件只负责生命周期与安全退出；
//! Runtime 的选择、校验和创建仍在 activation／main 中完成。
const std = @import("std");
const vne = @import("vne");
const abi = vne.abi;
const lifecycle = vne.lifecycle;
const launch = vne.launch;
const Control = vne.environment_control.Control;
const lock_port = @import("ports").instance_lock;
const activation = @import("activation");

const max_jobs_json = 256 * 1024;

/// Persistent lifecycle record plus the single-writer locks of one data root.
pub const Lifecycle = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    lock: lock_port.Lock,
    legacy_lock: lock_port.Lock,
    current: lifecycle.Snapshot,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, mode: launch.Mode) !Lifecycle {
        if (!std.fs.path.isAbsolute(data_dir)) return error.InvalidDataDirectory;
        var lock = try lock_port.acquire(allocator, io, data_dir, lifecycle.lock_path);
        errdefer lock.deinit();
        var legacy_lock = try lock_port.acquire(allocator, io, data_dir, lifecycle.legacy_lock_path);
        errdefer legacy_lock.deinit();
        const previous = try readPersisted(allocator, io, data_dir, mode);
        var self = Lifecycle{
            .allocator = allocator,
            .io = io,
            .data_dir = data_dir,
            .lock = lock,
            .legacy_lock = legacy_lock,
            .current = .{
                .state = .starting,
                .mode = mode,
                .boot_id = previous.boot_id + 1,
                .last_shutdown_abnormal = previous.state != .stopped,
                .abi_version = abi.version,
            },
        };
        try self.persist();
        return self;
    }

    pub fn deinit(self: *Lifecycle) void {
        self.legacy_lock.deinit();
        self.lock.deinit();
        self.* = undefined;
    }

    fn persist(self: *Lifecycle) !void {
        var buffer: [lifecycle.max_record]u8 = undefined;
        const encoded = try lifecycle.writeSnapshot(&buffer, self.current);
        const path = try std.fs.path.join(self.allocator, &.{ self.data_dir, lifecycle.record_path });
        defer self.allocator.free(path);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{ .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, encoded);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }

    fn transition(self: *Lifecycle, next: lifecycle.State) !void {
        const previous = self.current;
        self.current.state = next;
        if (next == .stopped) self.current.last_shutdown_abnormal = false;
        self.persist() catch |err| {
            self.current = previous;
            return err;
        };
    }

    pub fn ready(self: *Lifecycle, document_fingerprint: u64) !void {
        if (self.current.state != .starting) return error.InvalidEnvironmentState;
        self.current.document_fingerprint = document_fingerprint;
        try self.transition(.running);
    }

    pub fn beginStop(self: *Lifecycle) !void {
        if (self.current.state == .stopping) return;
        if (self.current.state != .running and self.current.state != .degraded) return error.InvalidEnvironmentState;
        try self.transition(.stopping);
    }

    pub fn resumeWork(self: *Lifecycle) !void {
        if (self.current.state != .stopping) return error.InvalidEnvironmentState;
        try self.transition(.running);
    }

    pub fn completeStop(self: *Lifecycle, document_fingerprint: u64) !void {
        if (self.current.state != .stopping) return error.InvalidEnvironmentState;
        self.current.document_fingerprint = document_fingerprint;
        try self.transition(.stopped);
    }

    pub fn failStop(self: *Lifecycle) !void {
        try self.transition(.degraded);
    }
};

/// The last record of a data root. A missing record means no earlier instance.
pub fn readPersisted(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, mode: launch.Mode) !lifecycle.Snapshot {
    inline for (.{ lifecycle.record_path, lifecycle.legacy_record_path }) |relative| {
        const path = try std.fs.path.join(allocator, &.{ data_dir, relative });
        defer allocator.free(path);
        if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(lifecycle.max_record))) |text| {
            defer allocator.free(text);
            const snapshot = try lifecycle.parseSnapshot(text);
            if (snapshot.mode != mode) return error.EnvironmentModeMismatch;
            return snapshot;
        } else |err| if (err != error.FileNotFound) return err;
    }
    return .{ .mode = mode, .abi_version = abi.version };
}

/// Lifecycle, job driver and safe-exit control around one created Runtime.
/// Keep at a fixed address: the driver thread and `control` point into it.
pub const Environment = struct {
    allocator: std.mem.Allocator,
    api: *const activation.Api,
    handle: ?*anyopaque,
    lifecycle: Lifecycle,
    driver: vne.job_driver.Driver = undefined,
    driver_started: bool = false,
    /// Shell payload selection committed to `session/runtime.lock` on stop.
    selection: ?Selection = null,
    control: Control = undefined,

    pub const Selection = struct {
        runtime: *activation.Activation,
        identity: vne.runtime_lock.Identity,
        allow_migration: bool,
        committed: bool = false,

        pub fn commit(self: *Selection) !void {
            if (self.committed) return;
            try self.runtime.commitShell(self.identity, self.allow_migration);
            self.committed = true;
        }
    };

    /// `lifecycle` must already be initialised; `handle` already handshaken.
    pub fn start(self: *Environment, io: std.Io) !void {
        self.control = .{
            .context = self,
            .prepare_stop = prepareStop,
            .cancel_jobs = cancelJobs,
            .resume_work = resumeWork,
            .stop = stop,
            .jobs_read = jobsRead,
        };
        try self.driver.startPolling(io, self.handle, self.api.jobs_pump, 50);
        self.driver_started = true;
        try self.lifecycle.ready(try activation.fingerprint(self.api, self.handle));
    }

    /// Joins the driver. Runtime destruction must follow, never precede, this.
    pub fn deinit(self: *Environment) void {
        if (self.driver_started) self.driver.deinit();
        self.driver_started = false;
        self.lifecycle.deinit();
    }

    fn from(context: *anyopaque) *Environment {
        return @ptrCast(@alignCast(context));
    }

    fn setAdmission(self: *Environment, open: bool) !void {
        if (self.api.set_admission(self.handle, @intFromBool(open)) != abi.Status.ok) return error.AdmissionControlFailed;
    }

    fn prepareStop(context: *anyopaque) anyerror!void {
        const self = from(context);
        try self.lifecycle.beginStop();
        try self.setAdmission(false);
    }

    fn cancelJobs(context: *anyopaque) anyerror!void {
        const self = from(context);
        if (self.lifecycle.current.state != .stopping) return error.InvalidEnvironmentState;
        try activation.command(self.api, self.handle, "task.cancel_all", null);
        self.driver.notify();
    }

    fn resumeWork(context: *anyopaque) anyerror!void {
        const self = from(context);
        try self.lifecycle.resumeWork();
        try self.setAdmission(true);
        self.driver.resumeWork();
    }

    /// Flush terminal job outcomes, then save; a failure leaves the environment
    /// degraded but running so the App can retry.
    fn stop(context: *anyopaque) anyerror!void {
        const self = from(context);
        try self.lifecycle.beginStop();
        try self.setAdmission(false);
        if (self.selection) |*selection| try selection.commit();
        self.driver.pauseAndWait();
        saveForStop(self.api, self.handle) catch |err| {
            self.lifecycle.failStop() catch |persist_err| std.debug.print("[safe-exit] 记录降级状态失败: {s}\n", .{@errorName(persist_err)});
            // Degraded is still a running environment: business reopens until a retry.
            self.setAdmission(true) catch {};
            self.driver.resumeWork();
            return err;
        };
        try self.lifecycle.completeStop(activation.fingerprint(self.api, self.handle) catch self.lifecycle.current.document_fingerprint);
        std.debug.print("CUTRANS_ENVIRONMENT_STOPPED boot_id={d}\n", .{self.lifecycle.current.boot_id});
    }

    fn jobsRead(context: *anyopaque, allocator: std.mem.Allocator, after_id: u64) anyerror![]u8 {
        const self = from(context);
        return readJobs(allocator, self.api, self.handle, after_id);
    }

    /// Normal stop when the App returned without one (e.g. its window closed).
    pub fn finish(self: *Environment) void {
        if (self.control.stopped or self.lifecycle.current.state == .stopped) return;
        self.control.stopEnvironment() catch |err| {
            std.debug.print("CUTRANS_ENVIRONMENT_STOP_FAIL {s}\n", .{@errorName(err)});
        };
    }
};

pub fn saveForStop(api: *const activation.Api, handle: ?*anyopaque) !void {
    // A committed output must retain its known terminal outcome across a normal
    // stop. Flushing this record never starts another queued job.
    if (api.jobs_flush(handle) != abi.Status.ok) return error.JobsFlushFailed;
    try activation.command(api, handle, "doc.save", null);
}

/// One complete jobs page, sized by a first query and copied by a second.
pub fn readJobs(allocator: std.mem.Allocator, api: *const activation.Api, handle: ?*anyopaque, after_id: u64) ![]u8 {
    var required: usize = 0;
    const query_status = api.jobs_read(handle, after_id, null, 0, &required);
    if (query_status != abi.Status.buffer_too_small) return error.JobsReadFailed;
    if (required == 0 or required > max_jobs_json) return error.JobsReadFailed;
    const bytes = try allocator.alloc(u8, required);
    errdefer allocator.free(bytes);
    var actual: usize = 0;
    if (api.jobs_read(handle, after_id, bytes.ptr, bytes.len, &actual) != abi.Status.ok) return error.JobsReadFailed;
    if (actual == 0 or actual > bytes.len) return error.JobsReadFailed;
    return allocator.realloc(bytes, actual);
}

test "lifecycle counts boots, marks abnormal ends and holds the data root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var first = try Lifecycle.init(std.testing.allocator, std.testing.io, root, .portable);
    try std.testing.expectEqual(@as(u64, 1), first.current.boot_id);
    try std.testing.expect(!first.current.last_shutdown_abnormal);
    try std.testing.expectError(error.EnvironmentAlreadyRunning, Lifecycle.init(std.testing.allocator, std.testing.io, root, .portable));
    try first.ready(5);
    try first.beginStop();
    try first.resumeWork();
    try first.beginStop();
    try first.completeStop(6);
    first.deinit();
    var second = try Lifecycle.init(std.testing.allocator, std.testing.io, root, .portable);
    try std.testing.expectEqual(@as(u64, 2), second.current.boot_id);
    try std.testing.expect(!second.current.last_shutdown_abnormal);
    try second.ready(6);
    second.deinit();
    // Ending while running is an abnormal end for the next instance.
    var third = try Lifecycle.init(std.testing.allocator, std.testing.io, root, .portable);
    defer third.deinit();
    try std.testing.expectEqual(@as(u64, 3), third.current.boot_id);
    try std.testing.expect(third.current.last_shutdown_abnormal);
    try std.testing.expectError(error.EnvironmentModeMismatch, readPersisted(std.testing.allocator, std.testing.io, root, .installed));
}

test "a retired Host record continues the boot sequence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "session");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = lifecycle.legacy_record_path, .data = "cutrans_vm_host=1\nstate=stopped\nmode=portable\nboot_id=9\nlast_shutdown_abnormal=0\nabi=11\ndocument=1\npresent=0\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var record = try Lifecycle.init(std.testing.allocator, std.testing.io, root, .portable);
    defer record.deinit();
    try std.testing.expectEqual(@as(u64, 10), record.current.boot_id);
    try std.testing.expect(!record.current.last_shutdown_abnormal);
}
