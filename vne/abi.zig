const std = @import("std");
const launch = @import("launch.zig");

pub const version: u32 = 10;

pub const Status = struct {
    pub const ok: i32 = 0;
    pub const accepted: i32 = 1;
    pub const unknown_command: i32 = 2;
    pub const invalid_arguments: i32 = 3;
    pub const permission_denied: i32 = 4;
    pub const invalid_state: i32 = 5;
    pub const not_ready: i32 = 6;
    pub const queue_full: i32 = 7;
    pub const failed: i32 = 8;
    pub const cancelled: i32 = 9;
    pub const invalid_handle: i32 = 10;
    pub const abi_mismatch: i32 = 11;
    pub const out_of_memory: i32 = 12;
    pub const not_found: i32 = 13;
    pub const unsupported_capability: i32 = 14;
    pub const buffer_too_small: i32 = 15;
    pub const legacy_identity_unverified: i32 = 16;
};

pub fn nativeAbi() []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "windows-x64",
            .aarch64 => "windows-arm64",
            else => "windows-other",
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "linux-x64",
            .aarch64 => "linux-arm64",
            else => "linux-other",
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => "macos-x64",
            .aarch64 => "macos-arm64",
            else => "macos-other",
        },
        else => "unsupported-os",
    };
}

pub const ByteSlice = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

pub const Config = extern struct {
    struct_size: u32,
    abi_version: u32,
    mode: u32,
    reserved: u32 = 0,
    resource_dir: ByteSlice,
    data_dir: ByteSlice,
};

pub fn modeFromInt(value: u32) !launch.Mode {
    return switch (value) {
        0 => .development,
        1 => .portable,
        2 => .installed,
        else => error.InvalidMode,
    };
}

pub fn modeToInt(mode: launch.Mode) u32 {
    return switch (mode) {
        .development => 0,
        .portable => 1,
        .installed => 2,
    };
}

pub fn runtimeLibraryName() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "cutrans_vm_runtime.dll",
        .macos => "libcutrans_vm_runtime.dylib",
        else => "libcutrans_vm_runtime.so",
    };
}

pub const InputEvent = extern struct {
    struct_size: u32,
    abi_version: u32,
    kind: u8,
    action: u8,
    code: u16,
    mods: u8,
    reserved: [3]u8 = .{ 0, 0, 0 },
    context: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    text: ByteSlice = .{},
};

pub const InputRecordReport = extern struct {
    struct_size: u32,
    abi_version: u32,
    event_count: u64,
    time_ns: i64,
};

pub const FrameReport = extern struct {
    struct_size: u32,
    abi_version: u32,
    content_id: u64,
    generation: u64,
    t: i64,
    kind: u32,
    reserved: u32 = 0,
};

pub const PlaybackReport = extern struct {
    struct_size: u32,
    abi_version: u32,
    active: u32,
    reserved: u32 = 0,
    cursor: i64,
    frames: i64,
    offer_count: u64,
    underflow_count: u64,
    present_count: u64,
    last_t: i64,
};

pub const LibraryEntry = extern struct {
    struct_size: u32,
    abi_version: u32,
    id: u64,
    parent_id: u64,
    node_kind: u32,
    kind: u32 = 0,
    provenance: u32 = 0,
    reserved: u32 = 0,
    content_hash: [32]u8 = @splat(0),
};

pub const LibraryListReport = extern struct {
    struct_size: u32,
    abi_version: u32,
    revision: u64,
    count: u32,
    reserved: u32 = 0,
    entries: [64]LibraryEntry,
};

pub const AssetListEntry = extern struct {
    handle: u64 = 0,
    byte_length: u64 = 0,
    leases: u32 = 0,
    source_kind: u32 = 0,
    library_kind: u32 = 0,
    reserved: u32 = 0,
    library_id: u64 = 0,
    content_hash: [32]u8 = @splat(0),
    source_status: u32 = 0,
    reserved2: u32 = 0,
};

pub const AssetListReport = extern struct {
    struct_size: u32,
    abi_version: u32,
    revision: u64,
    count: u32,
    reserved: u32 = 0,
    entries: [16]AssetListEntry,
};

pub const AssetInfo = extern struct {
    struct_size: u32,
    abi_version: u32,
    handle: u64,
    byte_length: u64,
    content_hash: [32]u8,
    width: u32,
    height: u32,
    media_kind: u32,
    coverage: u32,
    reserved: u32 = 0,
};

pub const ShellRequest = extern struct {
    struct_size: u32,
    abi_version: u32,
    resource_dir: ByteSlice,
    open_path: ByteSlice,
    record_input: ByteSlice = .{},
    playback_frames: i64 = 0,
    asset_workspace: u32 = 0,
};

pub const ShellConfig = extern struct {
    struct_size: u32,
    abi_version: u32,
    mode: u32,
    reserved: u32 = 0,
    resource_dir: ByteSlice,
    data_dir: ByteSlice,
    open_path: ByteSlice,
    playback_frames: i64 = 0,
    asset_workspace: u32 = 0,
};

pub const ShellApi = extern struct {
    struct_size: u32,
    abi_version: u32,
    context: ?*anyopaque,
    command_result: *const fn (?*anyopaque, ByteSlice, ByteSlice, ?*u64) callconv(.c) i32,
    document_fingerprint: *const fn (?*anyopaque, ?*u64) callconv(.c) i32,
    document_flags: *const fn (?*anyopaque, ?*u32) callconv(.c) i32,
    document_read: *const fn (?*anyopaque, ?[*]u8, usize, ?*usize) callconv(.c) i32,
    pump: *const fn (?*anyopaque) callconv(.c) i32,
    input_push: *const fn (?*anyopaque, ?*const InputEvent, ?*u64) callconv(.c) i32,
    input_flush: *const fn (?*anyopaque) callconv(.c) i32,
    frame_report: *const fn (?*anyopaque, ?*const FrameReport) callconv(.c) i32,
    playback_report: *const fn (?*anyopaque, ?*PlaybackReport) callconv(.c) i32,
    library_list: *const fn (?*anyopaque, ?*LibraryListReport) callconv(.c) i32,
    library_label: *const fn (?*anyopaque, u64, ?[*]u8, usize, ?*usize) callconv(.c) i32,
    asset_list: *const fn (?*anyopaque, ?*AssetListReport) callconv(.c) i32,
    asset_source: *const fn (?*anyopaque, u64, ?[*]u8, usize, ?*usize) callconv(.c) i32,
    asset_preview: *const fn (?*anyopaque, u64, ?*AssetInfo) callconv(.c) i32,
    asset_read: *const fn (?*anyopaque, u64, ?[*]u8, usize, ?*usize) callconv(.c) i32,
    asset_open_external: *const fn (?*anyopaque, ByteSlice, ?*u64) callconv(.c) i32,
    workspace_api: *const fn (?*anyopaque, ?*@import("workspace.zig").Api) callconv(.c) i32,
    /// Read owned encoded Source bytes without creating a remote Station lease.
    source_read: *const fn (?*anyopaque, ByteSlice, ByteSlice, ?[*]u8, usize, ?*usize) callconv(.c) i32,
    resource_api: *const fn (?*anyopaque, ?*@import("resource_api.zig").Api) callconv(.c) i32,

    pub fn isCurrent(self: *const ShellApi) bool {
        return self.struct_size == @sizeOf(ShellApi) and self.abi_version == version;
    }
};

pub const ShellEntry = *const fn (?*const ShellConfig, ?*const ShellApi) callconv(.c) i32;

pub const ReplayReport = extern struct {
    struct_size: u32,
    abi_version: u32,
    kind: u32 = 0,
    input_events: u64 = 0,
    document_fingerprint: u64,
    history_count: u64,
    history_cursor: u64 = 0,
    task_count: u64,
    tasks_hash: u64,
    time_ns: i64,
    event_count: u64,
};

test "runtime ABI mode and library identity are explicit" {
    try std.testing.expectEqual(@as(u32, 0), modeToInt(.development));
    try std.testing.expectEqual(@as(u32, 1), modeToInt(.portable));
    try std.testing.expectEqual(@as(u32, 2), modeToInt(.installed));
    try std.testing.expectEqual(launch.Mode.installed, try modeFromInt(2));
    try std.testing.expectError(error.InvalidMode, modeFromInt(3));
    try std.testing.expect(runtimeLibraryName().len > 0);
}

test "ABI10 asset projection and old Shell tables fail closed" {
    try std.testing.expectEqual(@offsetOf(ShellApi, "workspace_api") + @sizeOf(@TypeOf(@as(ShellApi, undefined).workspace_api)), @offsetOf(ShellApi, "source_read"));
    try std.testing.expectEqual(@offsetOf(ShellApi, "source_read") + @sizeOf(@TypeOf(@as(ShellApi, undefined).source_read)), @offsetOf(ShellApi, "resource_api"));
    var table: ShellApi = undefined;
    table.struct_size = @sizeOf(ShellApi);
    table.abi_version = version;
    try std.testing.expect(table.isCurrent());
    table.struct_size = @offsetOf(ShellApi, "source_read");
    try std.testing.expect(!table.isCurrent());
    table.struct_size = @offsetOf(ShellApi, "resource_api");
    try std.testing.expect(!table.isCurrent());
    table.struct_size = @sizeOf(ShellApi);
    table.abi_version = 9;
    try std.testing.expect(!table.isCurrent());
    table.abi_version = version;
    table.struct_size = @sizeOf(ShellApi) + 1;
    try std.testing.expect(!table.isCurrent());
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(AssetListEntry));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(AssetListEntry, "content_hash"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(AssetListEntry, "source_status"));
    try std.testing.expectEqual(@as(usize, 76), @offsetOf(AssetListEntry, "reserved2"));
}
