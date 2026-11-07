const std = @import("std");
const vne = @import("vne");
const abi = vne.abi;
const runtime_pack = vne.runtime_pack;
const runtime_lock = vne.runtime_lock;
const Library = @import("ports").library.Library;

pub const Api = struct {
    library: Library,
    abi_version: *const fn () callconv(.c) u32,
    create: *const fn (?*const abi.Config, ?*?*anyopaque) callconv(.c) i32,
    destroy: *const fn (?*anyopaque) callconv(.c) void,
    command: *const fn (?*anyopaque, abi.ByteSlice, abi.ByteSlice) callconv(.c) i32,
    input_begin: *const fn (?*anyopaque, abi.ByteSlice) callconv(.c) i32,
    input_end: *const fn (?*anyopaque, ?*abi.InputRecordReport) callconv(.c) i32,
    grant_external: *const fn (?*anyopaque, abi.ByteSlice, u32, ?*u64) callconv(.c) i32,
    capability_status: *const fn (?*anyopaque, abi.ByteSlice) callconv(.c) i32,
    fingerprint: *const fn (?*anyopaque, ?*u64) callconv(.c) i32,
    start_shell: *const fn (?*anyopaque, ?*const abi.ShellRequest) callconv(.c) i32,
    replay: *const fn (?*anyopaque, abi.ByteSlice, ?*abi.ReplayReport) callconv(.c) i32,
    jobs_pump: *const fn (?*anyopaque, ?*u32) callconv(.c) i32,
    jobs_read: *const fn (?*anyopaque, u64, ?[*]u8, usize, ?*usize) callconv(.c) i32,
    jobs_flush: *const fn (?*anyopaque) callconv(.c) i32,

    pub fn close(self: *Api) void {
        self.library.close();
    }
};

fn loadApi(allocator: std.mem.Allocator, root: []const u8, entry: []const u8) !Api {
    const path = try std.fs.path.join(allocator, &.{ root, entry });
    defer allocator.free(path);
    var library = try Library.open(allocator, path);
    errdefer library.close();
    const api = Api{
        .library = library,
        .abi_version = library.lookup(@TypeOf(@as(Api, undefined).abi_version), "cutrans_vm_abi_version") orelse return error.MissingRuntimeSymbol,
        .create = library.lookup(@TypeOf(@as(Api, undefined).create), "cutrans_vm_create") orelse return error.MissingRuntimeSymbol,
        .destroy = library.lookup(@TypeOf(@as(Api, undefined).destroy), "cutrans_vm_destroy") orelse return error.MissingRuntimeSymbol,
        .command = library.lookup(@TypeOf(@as(Api, undefined).command), "cutrans_vm_command") orelse return error.MissingRuntimeSymbol,
        .input_begin = library.lookup(@TypeOf(@as(Api, undefined).input_begin), "cutrans_vm_input_begin") orelse return error.MissingRuntimeSymbol,
        .input_end = library.lookup(@TypeOf(@as(Api, undefined).input_end), "cutrans_vm_input_end") orelse return error.MissingRuntimeSymbol,
        .grant_external = library.lookup(@TypeOf(@as(Api, undefined).grant_external), "cutrans_vm_grant_external") orelse return error.MissingRuntimeSymbol,
        .capability_status = library.lookup(@TypeOf(@as(Api, undefined).capability_status), "cutrans_vm_capability_status") orelse return error.MissingRuntimeSymbol,
        .fingerprint = library.lookup(@TypeOf(@as(Api, undefined).fingerprint), "cutrans_vm_document_fingerprint") orelse return error.MissingRuntimeSymbol,
        .start_shell = library.lookup(@TypeOf(@as(Api, undefined).start_shell), "cutrans_vm_start_shell") orelse return error.MissingRuntimeSymbol,
        .replay = library.lookup(@TypeOf(@as(Api, undefined).replay), "cutrans_vm_replay") orelse return error.MissingRuntimeSymbol,
        .jobs_pump = library.lookup(@TypeOf(@as(Api, undefined).jobs_pump), "cutrans_vm_jobs_pump") orelse return error.MissingRuntimeSymbol,
        .jobs_read = library.lookup(@TypeOf(@as(Api, undefined).jobs_read), "cutrans_vm_jobs_read") orelse return error.MissingRuntimeSymbol,
        .jobs_flush = library.lookup(@TypeOf(@as(Api, undefined).jobs_flush), "cutrans_vm_jobs_flush") orelse return error.MissingRuntimeSymbol,
    };
    if (api.abi_version() != abi.version) return error.RuntimeAbiMismatch;
    return api;
}

pub fn slice(value: []const u8) abi.ByteSlice {
    return .{ .ptr = value.ptr, .len = value.len };
}

pub fn packIdentity(allocator: std.mem.Allocator, io: std.Io, root: []const u8, manifest_path: []const u8, manifest: runtime_pack.Manifest) !runtime_lock.Identity {
    const full_path = try std.fs.path.join(allocator, &.{ root, manifest_path });
    defer allocator.free(full_path);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return .{
        .id = manifest.id,
        .version = manifest.version,
        .abi = manifest.abi,
        .manifest_sha256 = std.fmt.bytesToHex(digest, .lower),
    };
}

pub fn create(api: *const Api, config: *const abi.Config) !?*anyopaque {
    var handle: ?*anyopaque = null;
    if (api.create(config, &handle) != abi.Status.ok) return error.RuntimeCreateFailed;
    return handle orelse error.MissingRuntimeHandle;
}

pub fn command(api: *const Api, handle: ?*anyopaque, name: []const u8, arg: ?[]const u8) !void {
    const arg_slice = if (arg) |value| slice(value) else abi.ByteSlice{};
    if (api.command(handle, slice(name), arg_slice) != abi.Status.ok) return error.RuntimeCommandFailed;
}

pub fn handshake(api: *const Api, handle: ?*anyopaque, manifest: runtime_pack.Manifest) !void {
    for (manifest.required_capabilities) |id| {
        if (api.capability_status(handle, slice(id)) != abi.Status.ok) return error.RuntimeCapabilityMismatch;
    }
}

pub fn fingerprint(api: *const Api, handle: ?*anyopaque) !u64 {
    var value: u64 = 0;
    if (api.fingerprint(handle, &value) != abi.Status.ok) return error.RuntimeFingerprintFailed;
    return value;
}

pub fn presentCount(api: *const abi.ShellApi) !u64 {
    var report: abi.PlaybackReport = undefined;
    if (api.playback_report(api.context, &report) != abi.Status.ok) return error.PresentStatusFailed;
    return report.present_count;
}

pub const Activation = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    resource_dir: std.Io.Dir,
    data_dir: []const u8,
    manifest: std.json.Parsed(runtime_pack.Manifest),
    identity: runtime_lock.Identity,
    lock: ?runtime_lock.Owned,
    api: Api,
    committed: bool = false,

    pub fn prepare(allocator: std.mem.Allocator, io: std.Io, runtime_dir: []const u8, data_dir: []const u8, explicit_runtime: bool) !Activation {
        if (std.mem.eql(u8, runtime_dir, data_dir)) return error.SharedResourceAndDataDirectory;
        var resource_dir = try std.Io.Dir.openDirAbsolute(io, runtime_dir, .{});
        errdefer resource_dir.close(io);
        const parsed = try runtime_pack.verifyFile(allocator, io, resource_dir);
        errdefer parsed.deinit();
        const selected = try packIdentity(allocator, io, runtime_dir, runtime_pack.manifest_path, parsed.value);
        const lock = try runtime_lock.load(allocator, io, data_dir);
        errdefer if (lock) |value| {
            var owned = value;
            owned.deinit();
        };
        if (lock) |owned| {
            if (!runtime_lock.identityEqual(owned.selection.runtime, selected) and !explicit_runtime) {
                std.debug.print("[runtime-lock] 默认 Runtime 与 Session 锁定不一致;请显式 --runtime=<绝对目录> 迁移或回滚\n", .{});
                return error.RuntimeLockMismatch;
            }
        }
        return .{
            .allocator = allocator,
            .io = io,
            .resource_dir = resource_dir,
            .data_dir = data_dir,
            .manifest = parsed,
            .identity = selected,
            .lock = lock,
            .api = try loadApi(allocator, runtime_dir, parsed.value.entry),
        };
    }

    pub fn deinit(self: *Activation) void {
        self.api.close();
        if (self.lock) |*owned| owned.deinit();
        self.manifest.deinit();
        self.resource_dir.close(self.io);
        self.* = undefined;
    }

    fn reloadLock(self: *Activation) !void {
        const updated = try runtime_lock.load(self.allocator, self.io, self.data_dir);
        if (self.lock) |*owned| owned.deinit();
        self.lock = updated;
    }

    pub fn commit(self: *Activation) !void {
        if (self.committed) return error.RuntimeAlreadyCommitted;
        try runtime_pack.verify(self.manifest.value, self.allocator, self.io, self.resource_dir);
        try runtime_lock.save(.{ .runtime = self.identity, .shell = if (self.lock) |owned| owned.selection.shell else null }, self.allocator, self.io, self.data_dir);
        try self.reloadLock();
        self.committed = true;
    }

    pub fn checkShell(self: *const Activation, identity: runtime_lock.Identity, allow_migration: bool) !void {
        if (!self.committed) return error.RuntimeNotCommitted;
        if (self.lock) |owned| {
            if (owned.selection.shell) |locked| {
                if (!runtime_lock.identityEqual(locked, identity) and !allow_migration) return error.ShellLockMismatch;
            }
        }
    }

    pub fn commitShell(self: *Activation, identity: runtime_lock.Identity, allow_migration: bool) !void {
        try self.checkShell(identity, allow_migration);
        if (self.lock) |owned| {
            if (owned.selection.shell) |locked| {
                if (runtime_lock.identityEqual(locked, identity)) return;
            }
        }
        try runtime_lock.save(.{ .runtime = self.identity, .shell = identity }, self.allocator, self.io, self.data_dir);
        try self.reloadLock();
    }
};
