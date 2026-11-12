const std = @import("std");
const abi = @import("vne").abi;
const library_client = @import("library_client.zig");

fn validateApi(api: *const abi.ShellApi) !void {
    if (!api.isCurrent()) return error.InvalidShellApi;
    if (api.context == null) return error.MissingRuntimeHandle;
}

/// Register one host file through Resource API v4. The returned id is a VM
/// library id, not an asset handle; callers must refresh/ensure before use.
pub fn registerExternal(allocator: std.mem.Allocator, api: *const abi.ShellApi, io: *const std.Io, path: []const u8) !u64 {
    try validateApi(api);
    var client = try library_client.Client.init(allocator, api, library_client.NonceSource.secure(io));
    defer client.deinit();
    try client.refresh();
    try client.probe(0, .register_file, path);
    const settlement = switch (try client.submit()) {
        .known => |value| value,
        // Only the original candidate is retried; a lost reply is not a new
        // registration intent.
        .unknown => switch (try client.retry()) {
            .known => |value| value,
            .unknown => return error.ExternalRegistrationUnknown,
        },
    };
    if (settlement.outcome.status == abi.Status.queue_full) return error.ResourceCapacityReached;
    if (settlement.outcome.status != abi.Status.ok or settlement.outcome.resource_id == 0) {
        return error.ExternalRegistrationFailed;
    }
    return settlement.outcome.resource_id;
}

pub fn command(api: *const abi.ShellApi, name: []const u8, arg: ?[]const u8) !i32 {
    try validateApi(api);
    var task_id: u64 = 0;
    return api.command_result(api.context, .{ .ptr = name.ptr, .len = name.len }, if (arg) |value| .{ .ptr = value.ptr, .len = value.len } else .{}, &task_id);
}

pub fn syncLibrary(allocator: std.mem.Allocator, api: *const abi.ShellApi, view: *@import("vne").library.View) !void {
    try validateApi(api);
    var report: abi.LibraryListReport = undefined;
    if (api.library_list(api.context, &report) != abi.Status.ok) return error.LibraryMirrorFailed;
    if (report.struct_size < @sizeOf(abi.LibraryListReport) or report.abi_version != abi.version or report.reserved != 0 or report.count > view.items.len) return error.InvalidLibraryMirror;
    if (view.revision == report.revision) return;
    var next: @import("vne").library.View = .{};
    errdefer next.deinit(allocator);
    for (report.entries[0..report.count], 0..) |entry, index| {
        if (entry.struct_size < @sizeOf(abi.LibraryEntry) or entry.abi_version != abi.version or entry.id == 0 or entry.reserved != 0) return error.InvalidLibraryMirror;
        const node_kind = std.enums.fromInt(@import("vne").library.NodeKind, entry.node_kind) orelse return error.InvalidLibraryMirror;
        var kind: ?@import("vne").library.Kind = null;
        var provenance: ?@import("vne").library.Provenance = null;
        switch (node_kind) {
            .folder => if (entry.kind != 0 or entry.provenance != 0) return error.InvalidLibraryMirror,
            .resource => {
                kind = std.enums.fromInt(@import("vne").library.Kind, entry.kind) orelse return error.InvalidLibraryMirror;
                provenance = std.enums.fromInt(@import("vne").library.Provenance, entry.provenance) orelse return error.InvalidLibraryMirror;
            },
        }
        var required: usize = 0;
        if (api.library_label(api.context, entry.id, null, 0, &required) != abi.Status.buffer_too_small) return error.LibraryLabelReadFailed;
        if (required == 0 or required > 128) return error.InvalidLibraryMirror;
        const label = try allocator.alloc(u8, required);
        next.items[index] = .{
            .id = entry.id,
            .parent_id = entry.parent_id,
            .label = label,
            .node_kind = node_kind,
            .kind = kind,
            .provenance = provenance,
            .content_hash = entry.content_hash,
        };
        next.count = index + 1;
        if (api.library_label(api.context, entry.id, label.ptr, label.len, &required) != abi.Status.ok or required != label.len) return error.LibraryLabelReadFailed;
    }
    try next.validate();
    next.revision = report.revision;
    view.deinit(allocator);
    view.* = next;
}

pub fn syncAssets(allocator: std.mem.Allocator, api: *const abi.ShellApi, view: *@import("vne").assets.View) !void {
    try validateApi(api);
    var report: abi.AssetListReport = undefined;
    if (api.asset_list(api.context, &report) != abi.Status.ok) return error.AssetMirrorFailed;
    if (report.struct_size != @sizeOf(abi.AssetListReport) or report.abi_version != abi.version or report.reserved != 0 or report.count > view.items.len) return error.InvalidAssetMirror;
    for (report.entries[0..report.count]) |entry| {
        if (entry.handle == 0 or entry.source_kind > 3 or entry.library_kind > 2 or entry.reserved != 0 or entry.reserved2 != 0 or
            std.enums.fromInt(@import("vne").assets.SourceStatus, entry.source_status) == null) return error.InvalidAssetMirror;
    }
    if (view.revision == report.revision) return;
    var next: @import("vne").assets.View = .{};
    errdefer next.deinit(allocator);
    for (report.entries[0..report.count], 0..) |entry, index| {
        var required: usize = 0;
        if (api.asset_source(api.context, entry.handle, null, 0, &required) != abi.Status.buffer_too_small) return error.AssetSourceReadFailed;
        const source = try allocator.alloc(u8, required);
        next.items[index] = .{
            .handle = entry.handle,
            .byte_length = entry.byte_length,
            .leases = entry.leases,
            .source_kind = entry.source_kind,
            .library_kind = entry.library_kind,
            .library_id = entry.library_id,
            .content_hash = entry.content_hash,
            .source_state = std.enums.fromInt(@import("vne").assets.SourceStatus, entry.source_status).?,
            .source = source,
        };
        next.count = index + 1;
        if (api.asset_source(api.context, entry.handle, source.ptr, source.len, &required) != abi.Status.ok or required != source.len) return error.AssetSourceReadFailed;
    }
    next.revision = report.revision;
    view.deinit(allocator);
    view.* = next;
}

/// A library id can have several immutable Station versions. A panel asks for
/// the exact catalog head it is displaying, never whichever handle came last.
pub fn findResourceHead(view: *const @import("vne").assets.View, id: u64, expected: [32]u8) ?u64 {
    for (view.items[0..view.count]) |item| {
        if (item.library_id == id and id != 0 and std.mem.eql(u8, &item.content_hash, &expected)) return item.handle;
    }
    return null;
}

/// Every explicit selection validates its viewed head with the authority,
/// including local matches: another client may have advanced the catalog.
/// Ensure is idempotent and does not acquire another lease on retry.
pub fn ensureLibrary(api: *const abi.ShellApi, allocator: std.mem.Allocator, view: *@import("vne").assets.View, id: u64, expected: [32]u8) !u64 {
    try validateApi(api);
    if (id == 0) return error.InvalidLibraryResource;
    const digest = std.fmt.bytesToHex(expected, .lower);
    var buffer: [96]u8 = undefined;
    const arg = try std.fmt.bufPrint(&buffer, "{d} {s}", .{ id, digest });
    const status = try command(api, "asset.ensure", arg);
    if (status != abi.Status.ok and status != abi.Status.accepted) return error.LibraryEnsureFailed;
    try syncAssets(allocator, api, view);
    return findResourceHead(view, id, expected) orelse error.AssetMirrorMissing;
}

pub fn sourceStatusText(status: @import("vne").assets.SourceStatus) []const u8 {
    return switch (status) {
        .unchecked => "尚未核对来源",
        .unchanged => "上次核对：来源一致",
        .missing => "上次核对：原文件缺失；已加载预览仍可用",
        .content_changed => "上次核对：原文件内容已变化；已加载版本仍可用",
        .identity_changed => "上次核对：原文件已被替换；已加载预览仍可用",
        .unverified => "上次核对：旧授权尚未确认；已加载预览仍可用",
        .unavailable => "上次核对：来源暂不可读；已加载预览仍可用",
        .superseded => "上次核对：目录已采用其它版本；已加载版本仍可用",
    };
}

pub fn openExternal(api: *const abi.ShellApi, path: []const u8) !u64 {
    try validateApi(api);
    var handle: u64 = 0;
    if (api.asset_open_external(api.context, .{ .ptr = path.ptr, .len = path.len }, &handle) != abi.Status.accepted or handle == 0) return error.ExternalAssetOpenFailed;
    return handle;
}

pub const Preview = struct {
    info: abi.AssetInfo,
    bytes: []u8,

    pub fn deinit(self: *Preview, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn previewPng(allocator: std.mem.Allocator, api: *const abi.ShellApi, handle: u64, expected_hash: ?[32]u8) !Preview {
    try validateApi(api);
    var info: abi.AssetInfo = undefined;
    const preview_status = api.asset_preview(api.context, handle, &info);
    if (preview_status != abi.Status.ok) {
        std.debug.print("CUTRANS_ASSET_PREVIEW_FAIL handle={d} status={d}\n", .{ handle, preview_status });
        return error.AssetPreviewFailed;
    }
    if (info.struct_size < @sizeOf(abi.AssetInfo) or info.abi_version != abi.version or info.handle != handle or info.media_kind != 1 or info.coverage != 1 or info.width == 0 or info.height == 0 or info.reserved != 0) return error.InvalidAssetPreview;
    if (expected_hash) |expected| {
        if (!std.mem.eql(u8, &expected, &info.content_hash)) return error.SourceContentMismatch;
    }
    var required: usize = 0;
    if (api.asset_read(api.context, handle, null, 0, &required) != abi.Status.buffer_too_small or required != info.byte_length or required > 16 * 1024 * 1024) return error.AssetReadFailed;
    const bytes = try allocator.alloc(u8, required);
    errdefer allocator.free(bytes);
    if (api.asset_read(api.context, handle, bytes.ptr, bytes.len, &required) != abi.Status.ok or required != bytes.len) return error.AssetReadFailed;
    var actual_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual_hash, .{});
    if (!std.mem.eql(u8, &actual_hash, &info.content_hash)) return error.AssetContentMismatch;
    if (!std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return error.AssetPreviewMismatch;
    return .{ .info = info, .bytes = bytes };
}

const HeadMock = struct {
    count: u32 = 1,
    revision: u64 = 1,
    commands: usize = 0,
    admissions: usize = 0,
    lose_reply: bool = false,
    reserved2: u32 = 0,
    source_status: u32 = @backingInt(@import("vne").assets.SourceStatus.missing),

    fn api(self: *HeadMock) abi.ShellApi {
        var value: abi.ShellApi = undefined;
        value.struct_size = @sizeOf(abi.ShellApi);
        value.abi_version = abi.version;
        value.context = self;
        value.command_result = ensure;
        value.asset_list = list;
        value.asset_source = source;
        return value;
    }

    fn ensure(pointer: ?*anyopaque, name: abi.ByteSlice, arg: abi.ByteSlice, task: ?*u64) callconv(.c) i32 {
        const self: *HeadMock = @ptrCast(@alignCast(pointer.?));
        self.commands += 1;
        if (task) |out| out.* = 0;
        if (!std.mem.eql(u8, name.ptr.?[0..name.len], "asset.ensure")) return abi.Status.unknown_command;
        const expected = "7 2222222222222222222222222222222222222222222222222222222222222222";
        if (!std.mem.eql(u8, arg.ptr.?[0..arg.len], expected)) return abi.Status.invalid_state;
        if (self.count == 1) {
            self.count = 2;
            self.revision += 1;
            self.admissions += 1;
        }
        if (self.lose_reply) {
            self.lose_reply = false;
            return abi.Status.failed;
        }
        return abi.Status.accepted;
    }

    fn list(pointer: ?*anyopaque, out: ?*abi.AssetListReport) callconv(.c) i32 {
        const self: *HeadMock = @ptrCast(@alignCast(pointer.?));
        out.?.* = .{ .struct_size = @sizeOf(abi.AssetListReport), .abi_version = abi.version, .revision = self.revision, .count = self.count, .entries = @splat(.{}) };
        out.?.entries[0] = .{ .handle = 11, .byte_length = 72, .leases = 1, .source_kind = 3, .library_kind = 1, .library_id = 7, .content_hash = @splat(0x11), .source_status = self.source_status, .reserved2 = self.reserved2 };
        if (self.count == 2) out.?.entries[1] = .{ .handle = 22, .byte_length = 72, .leases = 1, .source_kind = 3, .library_kind = 1, .library_id = 7, .content_hash = @splat(0x22) };
        return abi.Status.ok;
    }

    fn source(_: ?*anyopaque, _: u64, buffer: ?[*]u8, capacity: usize, length: ?*usize) callconv(.c) i32 {
        const text = "library://7";
        length.?.* = text.len;
        if (buffer == null or capacity < text.len) return abi.Status.buffer_too_small;
        @memcpy(buffer.?[0..text.len], text);
        return abi.Status.ok;
    }
};

test "library head matching ignores old versions and ensure retries never add a lease" {
    var remote = HeadMock{ .lose_reply = true };
    const api = remote.api();
    var view: @import("vne").assets.View = .{};
    defer view.deinit(std.testing.allocator);
    try syncAssets(std.testing.allocator, &api, &view);
    try std.testing.expectEqual(@as(?u64, 11), findResourceHead(&view, 7, @splat(0x11)));
    try std.testing.expect(findResourceHead(&view, 7, @splat(0x22)) == null);
    try std.testing.expectError(error.LibraryEnsureFailed, ensureLibrary(&api, std.testing.allocator, &view, 7, @splat(0x22)));
    try std.testing.expectEqual(@as(u64, 22), try ensureLibrary(&api, std.testing.allocator, &view, 7, @splat(0x22)));
    try std.testing.expectEqual(@as(u64, 22), try ensureLibrary(&api, std.testing.allocator, &view, 7, @splat(0x22)));
    try std.testing.expectEqual(@as(usize, 3), remote.commands);
    try std.testing.expectEqual(@as(usize, 1), remote.admissions);
    try std.testing.expectEqual(@as(u32, 1), view.find(11).?.leases);
    try std.testing.expectEqual(@as(u32, 1), view.find(22).?.leases);
    try std.testing.expectEqual(@import("vne").assets.SourceStatus.missing, view.find(11).?.source_state);
}

test "a local resident match still validates an obsolete expected head with the authority" {
    var remote: HeadMock = .{};
    const api = remote.api();
    var view: @import("vne").assets.View = .{};
    defer view.deinit(std.testing.allocator);
    try syncAssets(std.testing.allocator, &api, &view);
    const source = view.find(11).?.source.ptr;
    try std.testing.expectEqual(@as(?u64, 11), findResourceHead(&view, 7, @splat(0x11)));
    // The authority's catalog has advanced to B while this panel still views A.
    try std.testing.expectError(error.LibraryEnsureFailed, ensureLibrary(&api, std.testing.allocator, &view, 7, @splat(0x11)));
    try std.testing.expectEqual(@as(usize, 1), remote.commands);
    try std.testing.expectEqual(@as(usize, 0), remote.admissions);
    try std.testing.expectEqual(source, view.find(11).?.source.ptr);
    try std.testing.expectEqual(@as(u32, 1), view.find(11).?.leases);
    try std.testing.expectEqual(@as(usize, 1), view.count);
}

test "asset projection rejects new reserved and status fields without replacing a valid view" {
    var remote: HeadMock = .{};
    const api = remote.api();
    var view: @import("vne").assets.View = .{};
    defer view.deinit(std.testing.allocator);
    try syncAssets(std.testing.allocator, &api, &view);
    const source = view.find(11).?.source.ptr;
    remote.reserved2 = 1;
    try std.testing.expectError(error.InvalidAssetMirror, syncAssets(std.testing.allocator, &api, &view));
    remote.reserved2 = 0;
    remote.source_status = 8;
    try std.testing.expectError(error.InvalidAssetMirror, syncAssets(std.testing.allocator, &api, &view));
    try std.testing.expectEqual(source, view.find(11).?.source.ptr);
    try std.testing.expectEqual(@import("vne").assets.SourceStatus.missing, view.find(11).?.source_state);
}
