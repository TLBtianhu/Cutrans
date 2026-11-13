const std = @import("std");
const vne = @import("vne");
const abi = vne.abi;
const runtime_pack = vne.runtime_pack;
const runtime_lock = vne.runtime_lock;
const Library = @import("ports").library.Library;

pub const ShellLoader = *const fn (*const Api, ?*anyopaque) anyerror!abi.ShellApi;

pub const Api = struct {
    library: ?Library = null,
    shell_api: ShellLoader,
    abi_version: *const fn () callconv(.c) u32,
    create: *const fn (?*const abi.Config, ?*?*anyopaque) callconv(.c) i32,
    destroy: *const fn (?*anyopaque) callconv(.c) void,
    command: *const fn (?*anyopaque, abi.ByteSlice, abi.ByteSlice) callconv(.c) i32,
    input_begin: *const fn (?*anyopaque, abi.ByteSlice) callconv(.c) i32,
    input_end: *const fn (?*anyopaque, ?*abi.InputRecordReport) callconv(.c) i32,
    grant_external: *const fn (?*anyopaque, abi.ByteSlice, u32, ?*u64) callconv(.c) i32,
    capability_status: *const fn (?*anyopaque, abi.ByteSlice) callconv(.c) i32,
    fingerprint: *const fn (?*anyopaque, ?*u64) callconv(.c) i32,
    set_admission: *const fn (?*anyopaque, u32) callconv(.c) i32,
    replay: *const fn (?*anyopaque, abi.ByteSlice, ?*abi.ReplayReport) callconv(.c) i32,
    jobs_pump: *const fn (?*anyopaque, ?*u32) callconv(.c) i32,
    jobs_read: *const fn (?*anyopaque, u64, ?[*]u8, usize, ?*usize) callconv(.c) i32,
    jobs_flush: *const fn (?*anyopaque) callconv(.c) i32,

    pub fn close(self: *Api) void {
        if (self.library) |*library| library.close();
        self.library = null;
    }
};

fn loadShellApi(self: *const Api, context: ?*anyopaque) !abi.ShellApi {
    const library = if (self.library) |*value| value else return error.RuntimeLibraryUnavailable;
    return .{
        .struct_size = @sizeOf(abi.ShellApi),
        .abi_version = abi.version,
        .context = context,
        .command_result = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).command_result), "cutrans_vm_command_result") orelse return error.MissingRuntimeSymbol,
        .document_fingerprint = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).document_fingerprint), "cutrans_vm_document_fingerprint") orelse return error.MissingRuntimeSymbol,
        .document_flags = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).document_flags), "cutrans_vm_document_flags") orelse return error.MissingRuntimeSymbol,
        .document_read = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).document_read), "cutrans_vm_document_read") orelse return error.MissingRuntimeSymbol,
        .pump = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).pump), "cutrans_vm_frame_pump") orelse return error.MissingRuntimeSymbol,
        .input_push = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).input_push), "cutrans_vm_input_push") orelse return error.MissingRuntimeSymbol,
        .input_flush = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).input_flush), "cutrans_vm_input_flush") orelse return error.MissingRuntimeSymbol,
        .frame_report = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).frame_report), "cutrans_vm_frame_report") orelse return error.MissingRuntimeSymbol,
        .playback_report = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).playback_report), "cutrans_vm_playback_report") orelse return error.MissingRuntimeSymbol,
        .library_list = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).library_list), "cutrans_vm_library_list") orelse return error.MissingRuntimeSymbol,
        .library_label = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).library_label), "cutrans_vm_library_label") orelse return error.MissingRuntimeSymbol,
        .asset_list = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).asset_list), "cutrans_vm_asset_list") orelse return error.MissingRuntimeSymbol,
        .asset_source = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).asset_source), "cutrans_vm_asset_source") orelse return error.MissingRuntimeSymbol,
        .asset_preview = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).asset_preview), "cutrans_vm_asset_preview") orelse return error.MissingRuntimeSymbol,
        .asset_read = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).asset_read), "cutrans_vm_asset_read") orelse return error.MissingRuntimeSymbol,
        .asset_open_external = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).asset_open_external), "cutrans_vm_asset_open_external") orelse return error.MissingRuntimeSymbol,
        .workspace_api = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).workspace_api), "cutrans_vm_workspace_api") orelse return error.MissingRuntimeSymbol,
        .source_read = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).source_read), "cutrans_vm_source_read") orelse return error.MissingRuntimeSymbol,
        .resource_api = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).resource_api), "cutrans_vm_resource_api") orelse return error.MissingRuntimeSymbol,
        .preview_info = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).preview_info), "cutrans_vm_preview_info") orelse return error.MissingRuntimeSymbol,
        .preview_read = library.lookup(@TypeOf(@as(abi.ShellApi, undefined).preview_read), "cutrans_vm_preview_read") orelse return error.MissingRuntimeSymbol,
    };
}

fn loadApi(allocator: std.mem.Allocator, root: []const u8, entry: []const u8) !Api {
    const path = try std.fs.path.join(allocator, &.{ root, entry });
    defer allocator.free(path);
    var library = try Library.open(allocator, path);
    errdefer library.close();
    const api = Api{
        .library = library,
        .shell_api = loadShellApi,
        .abi_version = library.lookup(@TypeOf(@as(Api, undefined).abi_version), "cutrans_vm_abi_version") orelse return error.MissingRuntimeSymbol,
        .create = library.lookup(@TypeOf(@as(Api, undefined).create), "cutrans_vm_create") orelse return error.MissingRuntimeSymbol,
        .destroy = library.lookup(@TypeOf(@as(Api, undefined).destroy), "cutrans_vm_destroy") orelse return error.MissingRuntimeSymbol,
        .command = library.lookup(@TypeOf(@as(Api, undefined).command), "cutrans_vm_command") orelse return error.MissingRuntimeSymbol,
        .input_begin = library.lookup(@TypeOf(@as(Api, undefined).input_begin), "cutrans_vm_input_begin") orelse return error.MissingRuntimeSymbol,
        .input_end = library.lookup(@TypeOf(@as(Api, undefined).input_end), "cutrans_vm_input_end") orelse return error.MissingRuntimeSymbol,
        .grant_external = library.lookup(@TypeOf(@as(Api, undefined).grant_external), "cutrans_vm_grant_external") orelse return error.MissingRuntimeSymbol,
        .capability_status = library.lookup(@TypeOf(@as(Api, undefined).capability_status), "cutrans_vm_capability_status") orelse return error.MissingRuntimeSymbol,
        .fingerprint = library.lookup(@TypeOf(@as(Api, undefined).fingerprint), "cutrans_vm_document_fingerprint") orelse return error.MissingRuntimeSymbol,
        .set_admission = library.lookup(@TypeOf(@as(Api, undefined).set_admission), "cutrans_vm_set_admission") orelse return error.MissingRuntimeSymbol,
        .replay = library.lookup(@TypeOf(@as(Api, undefined).replay), "cutrans_vm_replay") orelse return error.MissingRuntimeSymbol,
        .jobs_pump = library.lookup(@TypeOf(@as(Api, undefined).jobs_pump), "cutrans_vm_jobs_pump") orelse return error.MissingRuntimeSymbol,
        .jobs_read = library.lookup(@TypeOf(@as(Api, undefined).jobs_read), "cutrans_vm_jobs_read") orelse return error.MissingRuntimeSymbol,
        .jobs_flush = library.lookup(@TypeOf(@as(Api, undefined).jobs_flush), "cutrans_vm_jobs_flush") orelse return error.MissingRuntimeSymbol,
    };
    if (api.abi_version() != abi.version) return error.RuntimeAbiMismatch;
    return api;
}

pub fn staticApi(native: anytype, shell_loader: ShellLoader) !Api {
    const api = Api{
        .shell_api = shell_loader,
        .abi_version = native.cutrans_vm_abi_version,
        .create = native.cutrans_vm_create,
        .destroy = native.cutrans_vm_destroy,
        .command = native.cutrans_vm_command,
        .input_begin = native.cutrans_vm_input_begin,
        .input_end = native.cutrans_vm_input_end,
        .grant_external = native.cutrans_vm_grant_external,
        .capability_status = native.cutrans_vm_capability_status,
        .fingerprint = native.cutrans_vm_document_fingerprint,
        .set_admission = native.cutrans_vm_set_admission,
        .replay = native.cutrans_vm_replay,
        .jobs_pump = native.cutrans_vm_jobs_pump,
        .jobs_read = native.cutrans_vm_jobs_read,
        .jobs_flush = native.cutrans_vm_jobs_flush,
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

fn selectionLock(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, selected: runtime_lock.Identity, explicit_runtime: bool) !?runtime_lock.Owned {
    const lock = try runtime_lock.load(allocator, io, data_dir);
    errdefer if (lock) |value| {
        var owned = value;
        owned.deinit();
    };
    if (lock) |owned| {
        if (!runtime_lock.identityEqual(owned.selection.runtime, selected) and !explicit_runtime) {
            std.debug.print("[runtime-lock] 默认 Runtime 与 Session 锁定不一致;请显式选择 Runtime 迁移或回滚\n", .{});
            return error.RuntimeLockMismatch;
        }
    }
    return lock;
}

fn staticIdentity(allocator: std.mem.Allocator, manifest: runtime_pack.Manifest) !runtime_lock.Identity {
    const text = try std.json.Stringify.valueAlloc(allocator, manifest, .{});
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

pub const Activation = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    resource_dir: ?std.Io.Dir,
    data_dir: []const u8,
    manifest: ?std.json.Parsed(runtime_pack.Manifest),
    static_manifest: ?runtime_pack.Manifest,
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
        const lock = try selectionLock(allocator, io, data_dir, selected, explicit_runtime);
        errdefer if (lock) |value| {
            var owned = value;
            owned.deinit();
        };
        return .{
            .allocator = allocator,
            .io = io,
            .resource_dir = resource_dir,
            .data_dir = data_dir,
            .manifest = parsed,
            .static_manifest = null,
            .identity = selected,
            .lock = lock,
            .api = try loadApi(allocator, runtime_dir, parsed.value.entry),
        };
    }

    pub fn prepareStatic(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, explicit_runtime: bool, manifest: runtime_pack.Manifest, native: anytype, shell_loader: ShellLoader) !Activation {
        if (!std.mem.eql(u8, manifest.format, "cutrans-runtime-static/1") or !std.mem.eql(u8, manifest.entry, "builtin") or manifest.files.len != 0) return error.InvalidStaticRuntime;
        if (manifest.id.len == 0 or manifest.version.len == 0) return error.InvalidStaticRuntime;
        if (!std.mem.eql(u8, manifest.abi, abi.nativeAbi())) return error.IncompatibleRuntimeAbi;
        if (manifest.vm_schema != 1 or manifest.host_api != abi.version or manifest.document_schema != 3) return error.IncompatibleRuntimeSchema;
        const selected = try staticIdentity(allocator, manifest);
        const lock = try selectionLock(allocator, io, data_dir, selected, explicit_runtime);
        errdefer if (lock) |value| {
            var owned = value;
            owned.deinit();
        };
        return .{
            .allocator = allocator,
            .io = io,
            .resource_dir = null,
            .data_dir = data_dir,
            .manifest = null,
            .static_manifest = manifest,
            .identity = selected,
            .lock = lock,
            .api = try staticApi(native, shell_loader),
        };
    }

    pub fn descriptor(self: *const Activation) runtime_pack.Manifest {
        if (self.manifest) |parsed| return parsed.value;
        return self.static_manifest.?;
    }

    pub fn deinit(self: *Activation) void {
        self.api.close();
        if (self.lock) |*owned| owned.deinit();
        if (self.manifest) |*parsed| parsed.deinit();
        if (self.resource_dir) |*dir| dir.close(self.io);
        self.* = undefined;
    }

    fn reloadLock(self: *Activation) !void {
        const updated = try runtime_lock.load(self.allocator, self.io, self.data_dir);
        if (self.lock) |*owned| owned.deinit();
        self.lock = updated;
    }

    pub fn commit(self: *Activation) !void {
        if (self.committed) return error.RuntimeAlreadyCommitted;
        if (self.resource_dir) |dir| try runtime_pack.verify(self.manifest.?.value, self.allocator, self.io, dir);
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

test "static Runtime identity follows its semantic descriptor" {
    const capabilities = [_][]const u8{"node.testsrc"};
    const manifest = runtime_pack.Manifest{
        .format = "cutrans-runtime-static/1",
        .id = "cutrans-vm",
        .version = "0.1.0",
        .abi = "windows-x64",
        .entry = "builtin",
        .vm_schema = 1,
        .host_api = abi.version,
        .document_schema = 3,
        .required_capabilities = &capabilities,
        .files = &.{},
    };
    const first = try staticIdentity(std.testing.allocator, manifest);
    const second = try staticIdentity(std.testing.allocator, manifest);
    try std.testing.expect(runtime_lock.identityEqual(first, second));
    var changed = manifest;
    changed.required_capabilities = &.{};
    const different = try staticIdentity(std.testing.allocator, changed);
    try std.testing.expect(!runtime_lock.identityEqual(first, different));
}
