const std = @import("std");
const abi = @import("vne").abi;
const host_protocol = @import("vne").host_protocol;
const protocol = @import("protocol.zig");
const control = @import("ports").host_control;
const workspace = @import("vne").workspace;
const workspace_wire = protocol.workspace_wire;
const resource = @import("vne").resource_api;
const resource_wire = protocol.resource_wire;

const Client = struct {
    allocator: std.mem.Allocator,
    endpoint: []u8,
};

var client: Client = undefined;
var initialized = false;

fn verifyHost(allocator: std.mem.Allocator, endpoint: []const u8, mode: @import("vne").launch.Mode) !void {
    var request: [host_protocol.max_message]u8 = undefined;
    const encoded = try host_protocol.writeAction(&request, .status);
    var response: [host_protocol.max_message]u8 = undefined;
    const count = try control.request(allocator, endpoint, encoded, &response);
    const snapshot = try host_protocol.parseSnapshot(response[0..count]);
    if (snapshot.mode != mode or snapshot.abi_version != abi.version or snapshot.state != .running) return error.HostNotReady;
}

pub fn init(allocator: std.mem.Allocator, data_dir: []const u8, mode: @import("vne").launch.Mode) !void {
    if (initialized) return error.ShellAlreadyInitialized;
    const endpoint = try host_protocol.endpoint(allocator, data_dir);
    errdefer allocator.free(endpoint);
    try verifyHost(allocator, endpoint, mode);
    client = .{ .allocator = allocator, .endpoint = endpoint };
    initialized = true;
}

pub fn deinit() void {
    if (initialized) client.allocator.free(client.endpoint);
    client = undefined;
    initialized = false;
}

const Reply = struct {
    status: i32,
    value: u64,
    payload: []u8,

    fn deinit(self: *Reply) void {
        if (self.payload.len > 0) client.allocator.free(self.payload);
        self.* = undefined;
    }
};

fn call(kind: protocol.Kind, id: u64, payload: []const u8) !Reply {
    if (!initialized) return error.ShellNotInitialized;
    var header: [protocol.header_size]u8 = undefined;
    const encoded = try protocol.writeRequest(&header, .{ .kind = kind, .id = id, .payload_len = @intCast(payload.len) });
    var connection = try control.connect(client.allocator, client.endpoint);
    defer connection.deinit();
    try connection.writeMessage(encoded);
    if (payload.len > 0) try connection.writeMessage(payload);
    var response_header: [protocol.header_size]u8 = undefined;
    const header_len = try connection.readMessage(&response_header);
    const response = try protocol.parseResponse(response_header[0..header_len], kind);
    var response_payload: []u8 = &.{};
    if (response.payload_len > 0) response_payload = try client.allocator.alloc(u8, response.payload_len);
    errdefer if (response_payload.len > 0) client.allocator.free(response_payload);
    if (response_payload.len > 0) {
        const count = try connection.readMessage(response_payload);
        if (count != response_payload.len) return error.InvalidShellResponse;
    }
    return .{ .status = response.status, .value = response.value, .payload = response_payload };
}

fn read(bytes: abi.ByteSlice, required: bool) !?[]const u8 {
    if (bytes.len == 0) {
        if (required) return error.InvalidArguments;
        return null;
    }
    if (bytes.len > 1024 * 1024) return error.InvalidArguments;
    const ptr = bytes.ptr orelse return error.InvalidArguments;
    return ptr[0..bytes.len];
}

fn copyBytes(bytes: []const u8, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) i32 {
    const required = out_len orelse return abi.Status.invalid_arguments;
    required.* = bytes.len;
    const output = buffer orelse return abi.Status.buffer_too_small;
    if (buffer_len < bytes.len) return abi.Status.buffer_too_small;
    @memcpy(output[0..bytes.len], bytes);
    return abi.Status.ok;
}

fn copyFixed(comptime T: type, reply: Reply, out: *T) i32 {
    if (reply.status != abi.Status.ok) return reply.status;
    if (reply.payload.len != @sizeOf(T)) return abi.Status.failed;
    @memcpy(std.mem.asBytes(out), reply.payload);
    return abi.Status.ok;
}

fn commandResult(context: ?*anyopaque, name: abi.ByteSlice, arg: abi.ByteSlice, out_task_id: ?*u64) callconv(.c) i32 {
    _ = context;
    const command_name = read(name, true) catch return abi.Status.invalid_arguments;
    const command_arg = read(arg, false) catch return abi.Status.invalid_arguments;
    const arg_len = if (command_arg) |value| value.len else 0;
    const payload = client.allocator.alloc(u8, 8 + command_name.?.len + arg_len) catch return abi.Status.out_of_memory;
    defer client.allocator.free(payload);
    std.mem.writeInt(u32, payload[0..4], @intCast(command_name.?.len), .little);
    std.mem.writeInt(u32, payload[4..8], @intCast(arg_len), .little);
    @memcpy(payload[8 .. 8 + command_name.?.len], command_name.?);
    if (command_arg) |value| @memcpy(payload[8 + command_name.?.len ..], value);
    var reply = call(.command_result, 0, payload) catch return abi.Status.failed;
    defer reply.deinit();
    if (out_task_id) |out| out.* = reply.value;
    return reply.status;
}

fn workspaceSnapshot(context: ?*anyopaque, expected: ?*const workspace.Stamp, out: ?*workspace.Snapshot, buffer: ?[*]u8, capacity: usize, out_len: ?*usize) callconv(.c) i32 {
    _ = context;
    if (!initialized) return abi.Status.invalid_state;
    const metadata_out = out orelse return abi.Status.invalid_arguments;
    const length_out = out_len orelse return abi.Status.invalid_arguments;
    length_out.* = 0;
    if (buffer != null and expected == null) return abi.Status.invalid_arguments;
    var request: [workspace_wire.snapshot_request_size]u8 = undefined;
    const encoded = workspace_wire.writeSnapshotRequest(&request, expected) catch return abi.Status.invalid_arguments;
    var reply = call(.workspace_snapshot, 0, encoded) catch return abi.Status.failed;
    defer reply.deinit();
    if (reply.status != abi.Status.ok) return reply.status;
    if (reply.payload.len < workspace_wire.snapshot_size) return abi.Status.failed;
    const metadata = workspace_wire.readSnapshot(reply.payload[0..workspace_wire.snapshot_size]) catch return abi.Status.failed;
    const bytes = reply.payload[workspace_wire.snapshot_size..];
    if (metadata.text_len != bytes.len or (if (expected) |value| !metadata.stamp.eql(value.*) else false)) return abi.Status.failed;
    metadata_out.* = metadata;
    length_out.* = bytes.len;
    const output = buffer orelse return abi.Status.buffer_too_small;
    if (capacity < bytes.len) return abi.Status.buffer_too_small;
    @memcpy(output[0..bytes.len], bytes);
    return abi.Status.ok;
}

fn workspaceSubmit(context: ?*anyopaque, request: ?*const workspace.Request, out: ?*workspace.Outcome) callconv(.c) i32 {
    _ = context;
    if (!initialized) return abi.Status.invalid_state;
    const value = request orelse return abi.Status.invalid_arguments;
    const result_out = out orelse return abi.Status.invalid_arguments;
    const payload = workspace_wire.encodeRequest(client.allocator, value) catch |err| return switch (err) {
        error.OutOfMemory => abi.Status.out_of_memory,
        else => abi.Status.invalid_arguments,
    };
    defer client.allocator.free(payload);
    // A failed call leaves Outcome unknown. The caller retains the identical
    // request and can query its receipt by submitting it again, never a new ID.
    var reply = call(.workspace_submit, 0, payload) catch return abi.Status.failed;
    defer reply.deinit();
    if (reply.status != abi.Status.ok) return reply.status;
    const result = workspace_wire.readOutcome(reply.payload) catch return abi.Status.failed;
    if (result.sequence != value.sequence) return abi.Status.failed;
    result_out.* = result;
    return abi.Status.ok;
}

fn workspaceApi(context: ?*anyopaque, out: ?*workspace.Api) callconv(.c) i32 {
    _ = context;
    if (!initialized) return abi.Status.invalid_state;
    const result = out orelse return abi.Status.invalid_arguments;
    result.* = .{ .context = &client, .snapshot = workspaceSnapshot, .submit = workspaceSubmit };
    return abi.Status.ok;
}

fn resourceSnapshot(context: ?*anyopaque, expected: ?*const resource.Stamp, out: ?*resource.Snapshot, buffer: ?[*]u8, capacity: usize, out_len: ?*usize) callconv(.c) i32 {
    _ = context;
    const length_out = out_len orelse return abi.Status.invalid_arguments;
    length_out.* = 0;
    const metadata_out = out orelse return abi.Status.invalid_arguments;
    if (buffer != null and expected == null) return abi.Status.invalid_arguments;
    if (!initialized) return abi.Status.invalid_state;
    var request: [resource_wire.snapshot_request_size]u8 = undefined;
    const encoded = resource_wire.writeSnapshotRequest(&request, expected) catch return abi.Status.invalid_arguments;
    var reply = call(.resource_snapshot, 0, encoded) catch return abi.Status.failed;
    defer reply.deinit();
    if (reply.status != abi.Status.ok) return reply.status;
    if (reply.value != 0 or reply.payload.len < resource_wire.snapshot_size) return abi.Status.failed;
    const metadata = resource_wire.readSnapshot(reply.payload[0..resource_wire.snapshot_size]) catch return abi.Status.failed;
    const bytes = reply.payload[resource_wire.snapshot_size..];
    if (metadata.text_len != bytes.len or (if (expected) |value| !metadata.stamp.eql(value.*) else false)) return abi.Status.failed;
    metadata_out.* = metadata;
    length_out.* = bytes.len;
    const output = buffer orelse return abi.Status.buffer_too_small;
    if (capacity < bytes.len) return abi.Status.buffer_too_small;
    @memcpy(output[0..bytes.len], bytes);
    return abi.Status.ok;
}

fn resourceProbe(context: ?*anyopaque, request: ?*const resource.ProbeRequest, out: ?*resource.Proof) callconv(.c) i32 {
    _ = context;
    const value = request orelse return abi.Status.invalid_arguments;
    const proof_out = out orelse return abi.Status.invalid_arguments;
    if (!initialized) return abi.Status.invalid_state;
    const payload = resource_wire.encodeProbeRequest(client.allocator, value) catch |err| return switch (err) {
        error.OutOfMemory => abi.Status.out_of_memory,
        else => abi.Status.invalid_arguments,
    };
    defer client.allocator.free(payload);
    var reply = call(.resource_probe, 0, payload) catch return abi.Status.failed;
    defer reply.deinit();
    if (reply.status != abi.Status.ok) return reply.status;
    if (reply.value != 0) return abi.Status.failed;
    const proof = resource_wire.readProof(reply.payload) catch return abi.Status.failed;
    if (proof.target_id != value.target_id or proof.mode != value.mode or !proof.stamp.eql(value.expected)) return abi.Status.failed;
    proof_out.* = proof;
    return abi.Status.ok;
}

fn resourceSubmit(context: ?*anyopaque, request: ?*const resource.Request, out: ?*resource.Outcome) callconv(.c) i32 {
    _ = context;
    const value = request orelse return abi.Status.invalid_arguments;
    const result_out = out orelse return abi.Status.invalid_arguments;
    if (!initialized) return abi.Status.invalid_state;
    const payload = resource_wire.encodeRequest(client.allocator, value) catch |err| return switch (err) {
        error.OutOfMemory => abi.Status.out_of_memory,
        else => abi.Status.invalid_arguments,
    };
    defer client.allocator.free(payload);
    // The public library client owns Pending. This stateless bridge never
    // substitutes a new proof/stamp after a failed or malformed reply.
    var reply = call(.resource_submit, 0, payload) catch return abi.Status.failed;
    defer reply.deinit();
    if (reply.status != abi.Status.ok) return reply.status;
    if (reply.value != 0) return abi.Status.failed;
    const outcome = resource_wire.readOutcome(reply.payload) catch return abi.Status.failed;
    if (outcome.sequence != value.sequence) return abi.Status.failed;
    result_out.* = outcome;
    return abi.Status.ok;
}

fn resourceApi(context: ?*anyopaque, out: ?*resource.Api) callconv(.c) i32 {
    _ = context;
    if (!initialized) return abi.Status.invalid_state;
    const result = out orelse return abi.Status.invalid_arguments;
    result.* = .{ .context = &client, .snapshot = resourceSnapshot, .probe = resourceProbe, .submit = resourceSubmit };
    return abi.Status.ok;
}

fn documentFingerprint(context: ?*anyopaque, out_fingerprint: ?*u64) callconv(.c) i32 {
    _ = context;
    const out = out_fingerprint orelse return abi.Status.invalid_arguments;
    var reply = call(.document_fingerprint, 0, &.{}) catch return abi.Status.failed;
    defer reply.deinit();
    out.* = reply.value;
    return reply.status;
}

fn documentFlags(context: ?*anyopaque, out_flags: ?*u32) callconv(.c) i32 {
    _ = context;
    const out = out_flags orelse return abi.Status.invalid_arguments;
    var reply = call(.document_flags, 0, &.{}) catch return abi.Status.failed;
    defer reply.deinit();
    out.* = @intCast(reply.value);
    return reply.status;
}

fn documentRead(context: ?*anyopaque, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) callconv(.c) i32 {
    _ = context;
    var reply = call(.document_read, 0, &.{}) catch return abi.Status.failed;
    defer reply.deinit();
    if (reply.status != abi.Status.ok) return reply.status;
    return copyBytes(reply.payload, buffer, buffer_len, out_len);
}

fn pump(context: ?*anyopaque) callconv(.c) i32 {
    _ = context;
    var reply = call(.pump, 0, &.{}) catch return abi.Status.failed;
    defer reply.deinit();
    return reply.status;
}

fn inputPush(context: ?*anyopaque, input: ?*const abi.InputEvent, out_serial: ?*u64) callconv(.c) i32 {
    _ = context;
    const value = input orelse return abi.Status.invalid_arguments;
    const text = read(value.text, false) catch return abi.Status.invalid_arguments;
    var event = value.*;
    event.text.ptr = null;
    const text_len = if (text) |bytes| bytes.len else 0;
    const payload = client.allocator.alloc(u8, @sizeOf(abi.InputEvent) + text_len) catch return abi.Status.out_of_memory;
    defer client.allocator.free(payload);
    @memcpy(payload[0..@sizeOf(abi.InputEvent)], std.mem.asBytes(&event));
    if (text) |bytes| @memcpy(payload[@sizeOf(abi.InputEvent)..], bytes);
    var reply = call(.input_push, 0, payload) catch return abi.Status.failed;
    defer reply.deinit();
    if (out_serial) |out| out.* = reply.value;
    return reply.status;
}

fn inputFlush(context: ?*anyopaque) callconv(.c) i32 {
    _ = context;
    var reply = call(.input_flush, 0, &.{}) catch return abi.Status.failed;
    defer reply.deinit();
    return reply.status;
}

fn frameReport(context: ?*anyopaque, report: ?*const abi.FrameReport) callconv(.c) i32 {
    _ = context;
    const value = report orelse return abi.Status.invalid_arguments;
    var reply = call(.frame_report, 0, std.mem.asBytes(value)) catch return abi.Status.failed;
    defer reply.deinit();
    return reply.status;
}

fn playbackReport(context: ?*anyopaque, out_report: ?*abi.PlaybackReport) callconv(.c) i32 {
    _ = context;
    const out = out_report orelse return abi.Status.invalid_arguments;
    var reply = call(.playback_report, 0, &.{}) catch return abi.Status.failed;
    defer reply.deinit();
    return copyFixed(abi.PlaybackReport, reply, out);
}

fn libraryList(context: ?*anyopaque, out_report: ?*abi.LibraryListReport) callconv(.c) i32 {
    _ = context;
    const out = out_report orelse return abi.Status.invalid_arguments;
    var reply = call(.library_list, 0, &.{}) catch return abi.Status.failed;
    defer reply.deinit();
    return copyFixed(abi.LibraryListReport, reply, out);
}

fn libraryLabel(context: ?*anyopaque, id: u64, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) callconv(.c) i32 {
    _ = context;
    var reply = call(.library_label, id, &.{}) catch return abi.Status.failed;
    defer reply.deinit();
    if (reply.status != abi.Status.ok) return reply.status;
    return copyBytes(reply.payload, buffer, buffer_len, out_len);
}

fn assetList(context: ?*anyopaque, out_report: ?*abi.AssetListReport) callconv(.c) i32 {
    _ = context;
    const out = out_report orelse return abi.Status.invalid_arguments;
    var reply = call(.asset_list, 0, &.{}) catch return abi.Status.failed;
    defer reply.deinit();
    return copyFixed(abi.AssetListReport, reply, out);
}

fn assetSource(context: ?*anyopaque, id: u64, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) callconv(.c) i32 {
    _ = context;
    var reply = call(.asset_source, id, &.{}) catch return abi.Status.failed;
    defer reply.deinit();
    if (reply.status != abi.Status.ok) return reply.status;
    return copyBytes(reply.payload, buffer, buffer_len, out_len);
}

fn assetPreview(context: ?*anyopaque, id: u64, out_info: ?*abi.AssetInfo) callconv(.c) i32 {
    _ = context;
    const out = out_info orelse return abi.Status.invalid_arguments;
    var reply = call(.asset_preview, id, &.{}) catch return abi.Status.failed;
    defer reply.deinit();
    return copyFixed(abi.AssetInfo, reply, out);
}

fn assetRead(context: ?*anyopaque, id: u64, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) callconv(.c) i32 {
    _ = context;
    var reply = call(.asset_read, id, &.{}) catch return abi.Status.failed;
    defer reply.deinit();
    if (reply.status != abi.Status.ok) return reply.status;
    return copyBytes(reply.payload, buffer, buffer_len, out_len);
}

fn assetOpenExternal(context: ?*anyopaque, path: abi.ByteSlice, out_asset_id: ?*u64) callconv(.c) i32 {
    _ = context;
    const external_path = read(path, true) catch return abi.Status.invalid_arguments;
    const out = out_asset_id orelse return abi.Status.invalid_arguments;
    var reply = call(.asset_open_external, 0, external_path.?) catch return abi.Status.failed;
    defer reply.deinit();
    out.* = reply.value;
    return reply.status;
}

fn sourceRead(context: ?*anyopaque, uri: abi.ByteSlice, expected_sha256: abi.ByteSlice, buffer: ?[*]u8, buffer_len: usize, out_len: ?*usize) callconv(.c) i32 {
    _ = context;
    const out = out_len orelse return abi.Status.invalid_arguments;
    out.* = 0;
    if (!initialized) return abi.Status.invalid_state;
    const source = read(uri, true) catch return abi.Status.invalid_arguments;
    const expected = read(expected_sha256, false) catch return abi.Status.invalid_arguments;
    const payload = protocol.encodeSourceRead(client.allocator, source.?, expected orelse "") catch |err| return switch (err) {
        error.OutOfMemory => abi.Status.out_of_memory,
        else => abi.Status.invalid_arguments,
    };
    defer client.allocator.free(payload);
    var reply = call(.source_read, 0, payload) catch return abi.Status.failed;
    defer reply.deinit();
    if (reply.status != abi.Status.ok) return reply.status;
    if (reply.value != 0 or reply.payload.len == 0 or reply.payload.len > 16 * 1024 * 1024) return abi.Status.failed;
    return copyBytes(reply.payload, buffer, buffer_len, out);
}

fn selectIdentity(kind: protocol.Kind, identity: @import("vne").runtime_lock.Identity, allow_migration: bool) !void {
    const payload = try std.fmt.allocPrint(client.allocator, "id={s}\nversion={s}\nabi={s}\nmanifest_sha256={s}\n", .{ identity.id, identity.version, identity.abi, &identity.manifest_sha256 });
    defer client.allocator.free(payload);
    var reply = try call(kind, @intFromBool(allow_migration), payload);
    defer reply.deinit();
    if (reply.status != abi.Status.ok) return error.ShellLockMismatch;
}

pub fn handshake(identity: @import("vne").runtime_lock.Identity, allow_migration: bool) !void {
    return selectIdentity(.shell_handshake, identity, allow_migration);
}

pub fn commit(identity: @import("vne").runtime_lock.Identity, allow_migration: bool) !void {
    return selectIdentity(.shell_commit, identity, allow_migration);
}

pub fn inputBegin(path: []const u8) !void {
    var reply = try call(.input_begin, 0, path);
    defer reply.deinit();
    if (reply.status != abi.Status.ok) {
        std.debug.print("CUTRANS_INPUT_BEGIN_FAIL code={d}\n", .{reply.status});
        return error.InputRecordStartFailed;
    }
}

pub fn inputEnd() !abi.InputRecordReport {
    var reply = try call(.input_end, 0, &.{});
    defer reply.deinit();
    if (reply.status != abi.Status.ok) return error.InputRecordEndFailed;
    if (reply.payload.len != @sizeOf(abi.InputRecordReport)) return error.InvalidShellResponse;
    var report: abi.InputRecordReport = undefined;
    @memcpy(std.mem.asBytes(&report), reply.payload);
    if (report.struct_size < @sizeOf(abi.InputRecordReport) or report.abi_version != abi.version) return error.InvalidShellResponse;
    return report;
}

pub fn openDocument(path: []const u8) !void {
    var reply = try call(.document_open_external, 0, path);
    defer reply.deinit();
    if (reply.status != abi.Status.ok) return error.DocumentOpenFailed;
}

pub fn jobsRead(allocator: std.mem.Allocator, after_id: u64) ![]u8 {
    if (!initialized) return error.ShellNotInitialized;
    var reply = try call(.jobs_read, after_id, &.{});
    defer reply.deinit();
    if (reply.status != abi.Status.ok or reply.value != 0 or reply.payload.len == 0 or reply.payload.len > 256 * 1024) return error.JobsReadFailed;
    return allocator.dupe(u8, reply.payload);
}

pub fn api() abi.ShellApi {
    return .{
        .struct_size = @sizeOf(abi.ShellApi),
        .abi_version = abi.version,
        .context = &client,
        .command_result = commandResult,
        .document_fingerprint = documentFingerprint,
        .document_flags = documentFlags,
        .document_read = documentRead,
        .pump = pump,
        .input_push = inputPush,
        .input_flush = inputFlush,
        .frame_report = frameReport,
        .playback_report = playbackReport,
        .library_list = libraryList,
        .library_label = libraryLabel,
        .asset_list = assetList,
        .asset_source = assetSource,
        .asset_preview = assetPreview,
        .asset_read = assetRead,
        .asset_open_external = assetOpenExternal,
        .workspace_api = workspaceApi,
        .source_read = sourceRead,
        .resource_api = resourceApi,
    };
}

test "uninitialized workspace transport leaves edit outcome unknown" {
    const name = "editor.invert.add";
    const request = workspace.Request{ .client_hi = 1, .client_lo = 2, .sequence = 3, .expected = .{ .epoch_hi = 4, .epoch_lo = 5, .revision = 6 }, .name = .{ .ptr = name.ptr, .len = name.len } };
    const sentinel = workspace.Outcome{ .status = 123, .disposition = @backingInt(workspace.Disposition.executed), .sequence = 456, .stamp = .{ .epoch_hi = 7, .epoch_lo = 8, .revision = 9 }, .created_id = 10, .task_id = 11 };
    var outcome = sentinel;
    try std.testing.expectEqual(abi.Status.invalid_state, workspaceSubmit(null, &request, &outcome));
    try std.testing.expectEqualDeep(sentinel, outcome);
}

test "uninitialized source reading never returns a stale output length" {
    var length: usize = 999;
    try std.testing.expectEqual(abi.Status.invalid_state, sourceRead(null, .{ .ptr = "library://9".ptr, .len = "library://9".len }, .{}, null, 0, &length));
    try std.testing.expectEqual(@as(usize, 0), length);
}

test "workspace snapshot copy requires the version returned by its size query" {
    try std.testing.expect(!initialized);
    client = .{ .allocator = std.testing.allocator, .endpoint = &.{} };
    initialized = true;
    defer {
        initialized = false;
        client = undefined;
    }
    const sentinel = workspace.Snapshot{ .stamp = .{ .epoch_hi = 1, .epoch_lo = 2, .revision = 3 }, .fingerprint = 4, .node_id_high_water = 5, .flags = 0, .text_len = 6 };
    var metadata = sentinel;
    var buffer: [8]u8 = @splat(0xaa);
    var length: usize = 99;
    try std.testing.expectEqual(abi.Status.invalid_arguments, workspaceSnapshot(null, null, &metadata, &buffer, buffer.len, &length));
    try std.testing.expectEqualDeep(sentinel, metadata);
    try std.testing.expectEqual(@as(usize, 0), length);
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0xaa)), &buffer);
}

test "resource snapshot copy fails locally without its expected stamp" {
    var metadata = resource.Snapshot{ .stamp = .{ .epoch_hi = 1, .epoch_lo = 2 }, .text_len = 3 };
    const sentinel = metadata;
    var bytes: [8]u8 = @splat(0xaa);
    var length: usize = 99;
    try std.testing.expectEqual(abi.Status.invalid_arguments, resourceSnapshot(null, null, &metadata, &bytes, bytes.len, &length));
    try std.testing.expectEqualDeep(sentinel, metadata);
    try std.testing.expectEqual(@as(usize, 0), length);
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0xaa)), &bytes);
}
