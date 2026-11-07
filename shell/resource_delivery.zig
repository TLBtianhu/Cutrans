//! App handoff consumes a registered identity, never a host pathname. The
//! registration receipt is settled separately; rejection cannot erase it.
const std = @import("std");
const vne = @import("vne");
const mirror = @import("mirror.zig");

pub const Ref = struct { id: u64, content_hash: [32]u8 };

/// Construct handoff identity only from a known successful registration. The
/// candidate hash survives lost-reply retry; a later catalog head is unrelated.
pub fn fromSettlement(settlement: @import("library_client.zig").Settlement) !Ref {
    if (settlement.outcome.status != vne.abi.Status.ok or settlement.outcome.resource_id == 0 or settlement.previous_result_uncertain)
        return error.RegistrationNotConfirmed;
    return .{ .id = settlement.outcome.resource_id, .content_hash = settlement.content_hash };
}
pub const Consumer = struct {
    context: ?*anyopaque = null,
    /// Bytes are borrowed for this synchronous call only. A consumer keeps its
    /// own copy or version reference when accepting asynchronous work.
    accept: *const fn (?*anyopaque, Ref, []const u8) anyerror!void,
};
pub const Result = struct {
    resource: Ref,
    handle: u64,
    accepted: bool,
    consumer_error: ?anyerror = null,
};

pub fn acquire(allocator: std.mem.Allocator, api: *const vne.abi.ShellApi, view: *vne.assets.View, resource: Ref) !u64 {
    if (resource.id == 0) return error.InvalidResourceRef;
    var buffer: [96]u8 = undefined;
    const digest = std.fmt.bytesToHex(resource.content_hash, .lower);
    const arg = try std.fmt.bufPrint(&buffer, "{d} {s}", .{ resource.id, digest });
    const status = try mirror.command(api, "resource.acquire", arg);
    if (status != vne.abi.Status.ok and status != vne.abi.Status.accepted) return error.ResourceAcquireRefused;
    // A settled acquire and a projection failure are different outcomes.
    // Repeating this exact Ref is safe; it does not register a new resource.
    mirror.syncAssets(allocator, api, view) catch return error.ResourceAcquireProjectionFailed;
    return mirror.findResourceHead(view, resource.id, resource.content_hash) orelse error.ResourceAcquireProjectionFailed;
}

pub fn deliver(allocator: std.mem.Allocator, api: *const vne.abi.ShellApi, view: *vne.assets.View, resource: Ref, consumer: Consumer) !Result {
    const handle = try acquire(allocator, api, view, resource);
    var length: usize = 0;
    if (api.asset_read(api.context, handle, null, 0, &length) != vne.abi.Status.buffer_too_small or length > 16 * 1024 * 1024)
        return error.ResourcePayloadQueryFailed;
    const bytes = try allocator.alloc(u8, length);
    defer allocator.free(bytes);
    var actual: usize = 0;
    if (api.asset_read(api.context, handle, bytes.ptr, bytes.len, &actual) != vne.abi.Status.ok or actual != bytes.len)
        return error.ResourcePayloadReadFailed;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &resource.content_hash)) return error.ResourcePayloadMismatch;
    consumer.accept(consumer.context, resource, bytes) catch |err| return .{
        .resource = resource,
        .handle = handle,
        .accepted = false,
        .consumer_error = err,
    };
    return .{ .resource = resource, .handle = handle, .accepted = true };
}

const Mock = struct {
    calls: usize = 0,
    commands: usize = 0,
    command_status: i32 = vne.abi.Status.accepted,
    projection_status: i32 = vne.abi.Status.ok,
    rejected: bool = false,
    corrupt: bool = false,
    fn digest() [32]u8 {
        var value: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("txt", &value, .{});
        return value;
    }
    fn self(pointer: ?*anyopaque) *Mock {
        return @ptrCast(@alignCast(pointer.?));
    }
    fn command(pointer: ?*anyopaque, name: vne.abi.ByteSlice, _: vne.abi.ByteSlice, out: ?*u64) callconv(.c) i32 {
        const state = self(pointer);
        std.debug.assert(std.mem.eql(u8, name.ptr.?[0..name.len], "resource.acquire"));
        state.commands += 1;
        // This field is a Job id, never the acquired asset handle.
        out.?.* = 999;
        return state.command_status;
    }
    fn list(pointer: ?*anyopaque, out: ?*vne.abi.AssetListReport) callconv(.c) i32 {
        if (self(pointer).projection_status != 0) return self(pointer).projection_status;
        out.?.* = .{ .struct_size = @sizeOf(vne.abi.AssetListReport), .abi_version = vne.abi.version, .count = 1, .revision = 1, .entries = undefined };
        out.?.entries[0] = .{ .handle = 7, .byte_length = 3, .leases = 1, .source_kind = 3, .library_kind = 1, .library_id = 42, .content_hash = digest() };
        return 0;
    }
    fn source(_: ?*anyopaque, _: u64, buffer: ?[*]u8, capacity: usize, out: ?*usize) callconv(.c) i32 {
        const text = "library://42";
        out.?.* = text.len;
        if (buffer == null or capacity < text.len) return vne.abi.Status.buffer_too_small;
        @memcpy(buffer.?[0..text.len], text);
        return 0;
    }
    fn read(pointer: ?*anyopaque, id: u64, buffer: ?[*]u8, capacity: usize, out: ?*usize) callconv(.c) i32 {
        std.debug.assert(id == 7);
        out.?.* = 3;
        if (buffer == null or capacity < 3) return vne.abi.Status.buffer_too_small;
        @memcpy(buffer.?[0..3], if (self(pointer).corrupt) "bad" else "txt");
        return 0;
    }
    fn consume(pointer: ?*anyopaque, resource: Ref, bytes: []const u8) !void {
        const state = self(pointer);
        std.debug.assert(resource.id == 42 and std.mem.eql(u8, bytes, "txt"));
        state.calls += 1;
        if (state.rejected) return error.UnsupportedByApp;
    }
    fn api(state: *Mock) vne.abi.ShellApi {
        var value: vne.abi.ShellApi = undefined;
        value.struct_size = @sizeOf(vne.abi.ShellApi);
        value.abi_version = vne.abi.version;
        value.context = state;
        value.command_result = command;
        value.asset_list = list;
        value.asset_source = source;
        value.asset_read = read;
        return value;
    }
};

test "App rejection preserves a registered Ref and allows a separate delivery retry" {
    var state: Mock = .{ .rejected = true };
    const api = state.api();
    var view: vne.assets.View = .{};
    defer view.deinit(std.testing.allocator);
    const resource: Ref = .{ .id = 42, .content_hash = Mock.digest() };
    const consumer: Consumer = .{ .context = &state, .accept = Mock.consume };
    const first = try deliver(std.testing.allocator, &api, &view, resource, consumer);
    try std.testing.expect(!first.accepted and first.consumer_error.? == error.UnsupportedByApp);
    try std.testing.expectEqual(@as(u64, 42), first.resource.id);
    try std.testing.expectEqual(@as(u64, 7), first.handle);
    state.rejected = false;
    try std.testing.expect((try deliver(std.testing.allocator, &api, &view, resource, consumer)).accepted);
    try std.testing.expectEqual(@as(usize, 2), state.commands);
    try std.testing.expectEqual(@as(u32, 1), view.find(7).?.leases);
}

test "authority and projection failures do not invoke the consuming App" {
    var state: Mock = .{ .command_status = vne.abi.Status.permission_denied };
    const api = state.api();
    var view: vne.assets.View = .{};
    defer view.deinit(std.testing.allocator);
    const resource: Ref = .{ .id = 42, .content_hash = Mock.digest() };
    const consumer: Consumer = .{ .context = &state, .accept = Mock.consume };
    try std.testing.expectError(error.ResourceAcquireRefused, deliver(std.testing.allocator, &api, &view, resource, consumer));
    state.command_status = vne.abi.Status.accepted;
    state.projection_status = vne.abi.Status.failed;
    try std.testing.expectError(error.ResourceAcquireProjectionFailed, deliver(std.testing.allocator, &api, &view, resource, consumer));
    state.projection_status = 0;
    state.corrupt = true;
    try std.testing.expectError(error.ResourcePayloadMismatch, deliver(std.testing.allocator, &api, &view, resource, consumer));
    try std.testing.expectEqual(@as(usize, 0), state.calls);
}
