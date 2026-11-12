const std = @import("std");
const abi = @import("vne").abi;
const protocol = @import("shell").protocol;
const workspace = @import("vne").workspace;
const workspace_wire = protocol.workspace_wire;
const resource = @import("vne").resource_api;
const resource_wire = protocol.resource_wire;

pub const Reply = struct {
    status: i32 = abi.Status.ok,
    value: u64 = 0,
    payload: []u8 = &.{},
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *Reply) void {
        if (self.payload.len > 0) self.allocator.?.free(self.payload);
        self.* = undefined;
    }
};

fn slice(value: []const u8) abi.ByteSlice {
    return .{ .ptr = value.ptr, .len = value.len };
}

fn fixed(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return allocator.dupe(u8, std.mem.asBytes(&value));
}

fn readFixed(comptime T: type, bytes: []const u8) !T {
    if (bytes.len != @sizeOf(T)) return error.InvalidRpcPayload;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes);
    return value;
}

fn workspaceSnapshot(allocator: std.mem.Allocator, api: *const workspace.Api, expected: ?*const workspace.Stamp) !Reply {
    var metadata: workspace.Snapshot = undefined;
    var required: usize = 0;
    const size_status = api.snapshot(api.context, expected, &metadata, null, 0, &required);
    if (size_status != abi.Status.buffer_too_small and !(size_status == abi.Status.ok and required == 0)) return .{ .status = size_status };
    if (metadata.struct_size < @sizeOf(workspace.Snapshot) or metadata.api_version != workspace.version or metadata.reserved != 0 or
        required > protocol.max_payload - workspace_wire.snapshot_size or metadata.text_len != required) return error.InvalidRpcPayload;
    const bytes = try allocator.alloc(u8, workspace_wire.snapshot_size + required);
    errdefer allocator.free(bytes);
    var copied: usize = 0;
    var actual: workspace.Snapshot = undefined;
    const status = api.snapshot(api.context, &metadata.stamp, &actual, bytes[workspace_wire.snapshot_size..].ptr, required, &copied);
    if (status != abi.Status.ok) {
        allocator.free(bytes);
        return .{ .status = status };
    }
    if (copied != required or actual.text_len != copied or !actual.stamp.eql(metadata.stamp) or
        actual.fingerprint != metadata.fingerprint or actual.node_id_high_water != metadata.node_id_high_water or actual.flags != metadata.flags) return error.InvalidRpcPayload;
    _ = workspace_wire.writeSnapshot(bytes, actual) catch return error.InvalidRpcPayload;
    return .{ .payload = bytes, .allocator = allocator };
}

fn workspaceSubmit(allocator: std.mem.Allocator, api: *const workspace.Api, payload: []const u8) !Reply {
    const request = workspace_wire.readRequest(payload) catch return error.InvalidRpcPayload;
    var outcome: workspace.Outcome = undefined;
    const status = api.submit(api.context, &request, &outcome);
    if (status != abi.Status.ok) return .{ .status = status };
    const bytes = try allocator.alloc(u8, workspace_wire.outcome_size);
    errdefer allocator.free(bytes);
    _ = workspace_wire.writeOutcome(bytes, outcome) catch return error.InvalidRpcPayload;
    return .{ .payload = bytes, .allocator = allocator };
}

fn workspaceApi(api: *const abi.ShellApi, out: *workspace.Api) i32 {
    const status = api.workspace_api(api.context, out);
    if (status != abi.Status.ok) return status;
    if (out.struct_size < @sizeOf(workspace.Api) or out.api_version != workspace.version or out.context == null) return abi.Status.abi_mismatch;
    return abi.Status.ok;
}

fn resourceApi(api: *const abi.ShellApi, out: *resource.Api) i32 {
    if (!api.isCurrent()) return abi.Status.abi_mismatch;
    const status = api.resource_api(api.context, out);
    if (status != abi.Status.ok) return status;
    if (!out.isCurrent()) return abi.Status.abi_mismatch;
    return abi.Status.ok;
}

fn resourceSnapshot(allocator: std.mem.Allocator, api: *const resource.Api, expected: ?*const resource.Stamp) !Reply {
    var metadata: resource.Snapshot = undefined;
    var required: usize = 0;
    const query = api.snapshot(api.context, expected, &metadata, null, 0, &required);
    if (query != abi.Status.buffer_too_small) return .{ .status = if (query == abi.Status.ok) abi.Status.failed else query };
    if (metadata.struct_size != @sizeOf(resource.Snapshot) or metadata.api_version != resource.version or
        metadata.text_len != required or required > protocol.max_payload - resource_wire.snapshot_size or
        (if (expected) |value| !metadata.stamp.eql(value.*) else false)) return error.InvalidRpcPayload;
    const bytes = try allocator.alloc(u8, resource_wire.snapshot_size + required);
    errdefer allocator.free(bytes);
    var copied: usize = 0;
    var actual: resource.Snapshot = undefined;
    const status = api.snapshot(api.context, &metadata.stamp, &actual, bytes[resource_wire.snapshot_size..].ptr, required, &copied);
    if (status != abi.Status.ok) {
        allocator.free(bytes);
        return .{ .status = status };
    }
    if (copied != required or actual.text_len != copied or !actual.stamp.eql(metadata.stamp)) return error.InvalidRpcPayload;
    _ = resource_wire.writeSnapshot(bytes, actual) catch return error.InvalidRpcPayload;
    return .{ .payload = bytes, .allocator = allocator };
}

fn resourceProbe(allocator: std.mem.Allocator, api: *const resource.Api, payload: []const u8) !Reply {
    const request = resource_wire.readProbeRequest(payload) catch return error.InvalidRpcPayload;
    var proof: resource.Proof = undefined;
    const status = api.probe(api.context, &request, &proof);
    if (status != abi.Status.ok) return .{ .status = status };
    if (proof.target_id != request.target_id or proof.mode != request.mode or !proof.stamp.eql(request.expected)) return error.InvalidRpcPayload;
    const bytes = try allocator.alloc(u8, resource_wire.proof_size);
    errdefer allocator.free(bytes);
    _ = resource_wire.writeProof(bytes, proof) catch return error.InvalidRpcPayload;
    return .{ .payload = bytes, .allocator = allocator };
}

fn resourceSubmit(allocator: std.mem.Allocator, api: *const resource.Api, payload: []const u8) !Reply {
    const request = resource_wire.readRequest(payload) catch return error.InvalidRpcPayload;
    // Reserve reply storage before a mutation can commit. A dropped transport
    // reply still leaves the incarnation-local receipt available for retry.
    const bytes = try allocator.alloc(u8, resource_wire.outcome_size);
    errdefer allocator.free(bytes);
    var outcome: resource.Outcome = undefined;
    const status = api.submit(api.context, &request, &outcome);
    if (status != abi.Status.ok) {
        allocator.free(bytes);
        return .{ .status = status };
    }
    if (outcome.sequence != request.sequence) return error.InvalidRpcPayload;
    _ = resource_wire.writeOutcome(bytes, outcome) catch return error.InvalidRpcPayload;
    return .{ .payload = bytes, .allocator = allocator };
}

fn workSnapshot(allocator: std.mem.Allocator, api: *const resource.Api, id: u64, payload: []const u8) !Reply {
    if (id == 0) return error.InvalidRpcPayload;
    const expected: ?resource.WorkSnapshot = if (payload.len == 0) null else protocol.work_wire.readSnapshot(payload) catch return error.InvalidRpcPayload;
    var metadata: resource.WorkSnapshot = undefined;
    var required: usize = 0;
    const query = api.work_snapshot(api.context, id, null, &metadata, null, 0, &required);
    if (query != abi.Status.buffer_too_small) return .{ .status = if (query == abi.Status.ok) abi.Status.failed else query };
    var encoded: [protocol.work_wire.snapshot_size]u8 = undefined;
    _ = protocol.work_wire.writeSnapshot(&encoded, metadata) catch return error.InvalidRpcPayload;
    if (required != metadata.body_len or required > protocol.max_payload - protocol.work_wire.snapshot_size) return error.InvalidRpcPayload;
    if (expected) |value| if (!std.meta.eql(value, metadata)) return .{ .status = resource.Status.stale_version };
    const bytes = try allocator.alloc(u8, protocol.work_wire.snapshot_size + required);
    errdefer allocator.free(bytes);
    var actual: resource.WorkSnapshot = undefined;
    var copied: usize = 0;
    const status = api.work_snapshot(api.context, id, &metadata, &actual, bytes[protocol.work_wire.snapshot_size..].ptr, required, &copied);
    if (status != abi.Status.ok) {
        allocator.free(bytes);
        return .{ .status = status };
    }
    if (copied != required or !std.meta.eql(actual, metadata)) return error.InvalidRpcPayload;
    const body = bytes[protocol.work_wire.snapshot_size..];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    if (!std.mem.eql(u8, &digest, &actual.body_hash)) return error.InvalidRpcPayload;
    _ = protocol.work_wire.writeSnapshot(bytes, actual) catch return error.InvalidRpcPayload;
    return .{ .payload = bytes, .allocator = allocator };
}

fn workSubmit(allocator: std.mem.Allocator, api: *const resource.Api, payload: []const u8) !Reply {
    const decoded = protocol.work_wire.readRequest(payload) catch return error.InvalidRpcPayload;
    const bytes = try allocator.alloc(u8, protocol.work_wire.outcome_size);
    errdefer allocator.free(bytes);
    var outcome: resource.WorkOutcome = undefined;
    const status = api.work_submit(api.context, &decoded.value, &outcome);
    if (status != abi.Status.ok) {
        allocator.free(bytes);
        return .{ .status = status };
    }
    if (outcome.sequence != decoded.value.sequence) return error.InvalidRpcPayload;
    if (outcome.status == abi.Status.ok and (outcome.resource_id == 0 or outcome.work_revision == 0)) return error.InvalidRpcPayload;
    _ = protocol.work_wire.writeOutcome(bytes, outcome) catch return error.InvalidRpcPayload;
    return .{ .payload = bytes, .allocator = allocator };
}

fn localSourceReply(allocator: std.mem.Allocator, api: *const resource.Api, read_file: bool, payload: []const u8) !Reply {
    var path: []const u8 = undefined;
    var cursor: u64 = 0;
    var limit: u32 = 0;
    if (read_file) {
        path = protocol.source_wire.parseRead(payload) catch return error.InvalidRpcPayload;
    } else {
        const browse = protocol.source_wire.parseBrowse(payload) catch return error.InvalidRpcPayload;
        path = browse.path;
        cursor = browse.cursor;
        limit = browse.limit;
    }
    var required: usize = 0;
    const query = if (read_file)
        api.source_read(api.context, resource.Bytes{ .ptr = path.ptr, .len = path.len }, null, 0, &required)
    else
        api.source_browse(api.context, resource.Bytes{ .ptr = path.ptr, .len = path.len }, cursor, limit, null, 0, &required);
    if (query != abi.Status.buffer_too_small) return .{ .status = query };
    if (required > protocol.max_payload) return error.InvalidRpcPayload;
    const bytes = try allocator.alloc(u8, required);
    errdefer allocator.free(bytes);
    const status = if (read_file)
        api.source_read(api.context, resource.Bytes{ .ptr = path.ptr, .len = path.len }, bytes.ptr, bytes.len, &required)
    else
        api.source_browse(api.context, resource.Bytes{ .ptr = path.ptr, .len = path.len }, cursor, limit, bytes.ptr, bytes.len, &required);
    if (status != abi.Status.ok) {
        allocator.free(bytes);
        return .{ .status = status };
    }
    return .{ .payload = bytes, .allocator = allocator };
}

fn readBuffer(allocator: std.mem.Allocator, function: anytype, context: ?*anyopaque, id: u64) !Reply {
    var required: usize = 0;
    const size_status = function(context, id, null, 0, &required);
    if (size_status != abi.Status.buffer_too_small) return .{ .status = size_status };
    if (required > protocol.max_payload) return error.InvalidRpcPayload;
    const bytes = try allocator.alloc(u8, required);
    errdefer allocator.free(bytes);
    const status = function(context, id, bytes.ptr, bytes.len, &required);
    if (status != abi.Status.ok) {
        allocator.free(bytes);
        return .{ .status = status };
    }
    return .{ .payload = bytes, .allocator = allocator };
}

fn commandPayload(bytes: []const u8) !struct { name: []const u8, arg: ?[]const u8 } {
    if (bytes.len < 8) return error.InvalidRpcPayload;
    const name_len = std.mem.readInt(u32, bytes[0..4], .little);
    const arg_len = std.mem.readInt(u32, bytes[4..8], .little);
    if (name_len == 0 or @as(usize, name_len) + @as(usize, arg_len) + 8 != bytes.len) return error.InvalidRpcPayload;
    return .{
        .name = bytes[8 .. 8 + name_len],
        .arg = if (arg_len == 0) null else bytes[8 + name_len ..],
    };
}

fn readSource(allocator: std.mem.Allocator, api: *const abi.ShellApi, value: protocol.SourceRead) !Reply {
    var required: usize = 0;
    const query = api.source_read(api.context, slice(value.uri), slice(value.expected_sha256), null, 0, &required);
    if (query != abi.Status.buffer_too_small) return .{ .status = if (query == abi.Status.ok) abi.Status.failed else query };
    if (required == 0 or required > 16 * 1024 * 1024) return .{ .status = abi.Status.failed };
    const bytes = try allocator.alloc(u8, required);
    errdefer allocator.free(bytes);
    var actual: usize = 0;
    const status = api.source_read(api.context, slice(value.uri), slice(value.expected_sha256), bytes.ptr, bytes.len, &actual);
    if (status != abi.Status.ok) {
        allocator.free(bytes);
        return .{ .status = status };
    }
    if (actual == 0 or actual > bytes.len) return error.InvalidRpcPayload;
    return .{ .payload = try allocator.realloc(bytes, actual), .allocator = allocator };
}

pub fn shellIdentity(payload: []const u8) !@import("vne").runtime_lock.Identity {
    var id: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var native_abi: ?[]const u8 = null;
    var digest: ?[64]u8 = null;
    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "id=")) {
            if (id != null) return error.InvalidRpcPayload;
            id = line[3..];
        } else if (std.mem.startsWith(u8, line, "version=")) {
            if (version != null) return error.InvalidRpcPayload;
            version = line[8..];
        } else if (std.mem.startsWith(u8, line, "abi=")) {
            if (native_abi != null) return error.InvalidRpcPayload;
            native_abi = line[4..];
        } else if (std.mem.startsWith(u8, line, "manifest_sha256=")) {
            if (digest != null or line.len != 80) return error.InvalidRpcPayload;
            var value: [64]u8 = undefined;
            @memcpy(&value, line[16..]);
            digest = value;
        } else return error.InvalidRpcPayload;
    }
    return .{
        .id = id orelse return error.InvalidRpcPayload,
        .version = version orelse return error.InvalidRpcPayload,
        .abi = native_abi orelse return error.InvalidRpcPayload,
        .manifest_sha256 = digest orelse return error.InvalidRpcPayload,
    };
}

pub fn call(allocator: std.mem.Allocator, api: *const abi.ShellApi, grant_external: *const fn (?*anyopaque, abi.ByteSlice, u32, ?*u64) callconv(.c) i32, request: protocol.Request, payload: []const u8) !Reply {
    if (request.payload_len != payload.len) return error.InvalidRpcPayload;
    switch (request.kind) {
        .resource_snapshot, .resource_probe, .resource_submit => {
            if (request.id != 0) return error.InvalidRpcPayload;
            var authority: resource.Api = undefined;
            const status = resourceApi(api, &authority);
            if (status != abi.Status.ok) return .{ .status = status };
            return switch (request.kind) {
                .resource_snapshot => blk: {
                    const expected = resource_wire.readSnapshotRequest(payload) catch return error.InvalidRpcPayload;
                    break :blk resourceSnapshot(allocator, &authority, if (expected) |*value| value else null);
                },
                .resource_probe => resourceProbe(allocator, &authority, payload),
                .resource_submit => resourceSubmit(allocator, &authority, payload),
                else => unreachable,
            };
        },
        .workspace_snapshot => {
            if (request.id != 0) return error.InvalidRpcPayload;
            const expected = workspace_wire.readSnapshotRequest(payload) catch return error.InvalidRpcPayload;
            var api_v1: workspace.Api = undefined;
            const status = workspaceApi(api, &api_v1);
            if (status != abi.Status.ok) return .{ .status = status };
            return workspaceSnapshot(allocator, &api_v1, if (expected) |*value| value else null);
        },
        .workspace_submit => {
            if (request.id != 0) return error.InvalidRpcPayload;
            var api_v1: workspace.Api = undefined;
            const status = workspaceApi(api, &api_v1);
            if (status != abi.Status.ok) return .{ .status = status };
            return workspaceSubmit(allocator, &api_v1, payload);
        },
        .work_snapshot, .work_submit => {
            var authority: resource.Api = undefined;
            const status = resourceApi(api, &authority);
            if (status != abi.Status.ok) return .{ .status = status };
            if (request.kind == .work_snapshot) {
                if (request.id == 0) return error.InvalidRpcPayload;
                return workSnapshot(allocator, &authority, request.id, payload);
            }
            if (request.id != 0) return error.InvalidRpcPayload;
            return workSubmit(allocator, &authority, payload);
        },
        .source_browse, .local_read => {
            if (request.id != 0) return error.InvalidRpcPayload;
            var authority: resource.Api = undefined;
            const status = resourceApi(api, &authority);
            if (status != abi.Status.ok) return .{ .status = status };
            return localSourceReply(allocator, &authority, request.kind == .local_read, payload);
        },
        .preview_info => {
            if (request.id != 0 or (payload.len != 8 and payload.len != 24)) return error.InvalidRpcPayload;
            const expected = std.mem.readInt(u64, payload[0..8], .little);
            const expected_epoch: ?[2]u64 = if (payload.len == 24) .{ std.mem.readInt(u64, payload[8..16], .little), std.mem.readInt(u64, payload[16..24], .little) } else null;
            var info: abi.PreviewInfo = undefined;
            const status = api.preview_info(api.context, expected, &info);
            if (status == abi.Status.ok) if (expected_epoch) |epoch| {
                if (info.epoch_hi != epoch[0] or info.epoch_lo != epoch[1]) return .{ .status = abi.Status.invalid_state };
            };
            return .{ .status = status, .payload = if (status == abi.Status.ok) try fixed(allocator, info) else &.{}, .allocator = allocator };
        },
        .preview_read => {
            if (request.id != 0 or (payload.len != 8 and payload.len != 24)) return error.InvalidRpcPayload;
            const expected = std.mem.readInt(u64, payload[0..8], .little);
            const expected_epoch: ?[2]u64 = if (payload.len == 24) .{ std.mem.readInt(u64, payload[8..16], .little), std.mem.readInt(u64, payload[16..24], .little) } else null;
            var info: abi.PreviewInfo = undefined;
            const info_status = api.preview_info(api.context, expected, &info);
            if (info_status != abi.Status.ok) return .{ .status = info_status };
            if (expected_epoch) |epoch| {
                if (info.epoch_hi != epoch[0] or info.epoch_lo != epoch[1]) return .{ .status = abi.Status.invalid_state };
            }
            if (info.bytes_len > protocol.max_payload) return error.InvalidRpcPayload;
            const bytes = try allocator.alloc(u8, info.bytes_len);
            errdefer allocator.free(bytes);
            var required: usize = 0;
            const status = api.preview_read(api.context, expected, bytes.ptr, bytes.len, &required);
            if (status != abi.Status.ok or required != info.bytes_len) {
                allocator.free(bytes);
                return .{ .status = status };
            }
            return .{ .payload = bytes, .allocator = allocator };
        },
        .command_result => {
            const strings = try commandPayload(payload);
            var task_id: u64 = 0;
            const status = api.command_result(api.context, slice(strings.name), if (strings.arg) |arg| slice(arg) else .{}, &task_id);
            return .{ .status = status, .value = task_id };
        },
        .document_fingerprint => {
            var value: u64 = 0;
            const status = api.document_fingerprint(api.context, &value);
            return .{ .status = status, .value = value };
        },
        .document_flags => {
            var value: u32 = 0;
            const status = api.document_flags(api.context, &value);
            return .{ .status = status, .value = value };
        },
        .document_read => {
            var required: usize = 0;
            const size_status = api.document_read(api.context, null, 0, &required);
            if (size_status != abi.Status.buffer_too_small) return .{ .status = size_status };
            if (required > protocol.max_payload) return error.InvalidRpcPayload;
            const bytes = try allocator.alloc(u8, required);
            errdefer allocator.free(bytes);
            const status = api.document_read(api.context, bytes.ptr, bytes.len, &required);
            if (status != abi.Status.ok) {
                allocator.free(bytes);
                return .{ .status = status };
            }
            return .{ .payload = bytes, .allocator = allocator };
        },
        .pump => return .{ .status = api.pump(api.context) },
        .input_flush => return .{ .status = api.input_flush(api.context) },
        .input_push => {
            if (payload.len < @sizeOf(abi.InputEvent)) return error.InvalidRpcPayload;
            const event_size = @sizeOf(abi.InputEvent);
            var event = try readFixed(abi.InputEvent, payload[0..event_size]);
            if (event.text.len != payload.len - event_size) return error.InvalidRpcPayload;
            if (event.text.len > 0) event.text.ptr = payload[event_size..].ptr;
            var serial: u64 = 0;
            const status = api.input_push(api.context, &event, &serial);
            return .{ .status = status, .value = serial };
        },
        .frame_report => {
            const value = try readFixed(abi.FrameReport, payload);
            return .{ .status = api.frame_report(api.context, &value) };
        },
        .playback_report => {
            var report: abi.PlaybackReport = undefined;
            const status = api.playback_report(api.context, &report);
            return .{ .status = status, .payload = if (status == abi.Status.ok) try fixed(allocator, report) else &.{}, .allocator = allocator };
        },
        .library_list => {
            var report: abi.LibraryListReport = undefined;
            const status = api.library_list(api.context, &report);
            return .{ .status = status, .payload = if (status == abi.Status.ok) try fixed(allocator, report) else &.{}, .allocator = allocator };
        },
        .library_label => return readBuffer(allocator, api.library_label, api.context, request.id),
        .asset_list => {
            var report: abi.AssetListReport = undefined;
            const status = api.asset_list(api.context, &report);
            return .{ .status = status, .payload = if (status == abi.Status.ok) try fixed(allocator, report) else &.{}, .allocator = allocator };
        },
        .asset_source => return readBuffer(allocator, api.asset_source, api.context, request.id),
        .asset_preview => {
            var info: abi.AssetInfo = undefined;
            const status = api.asset_preview(api.context, request.id, &info);
            return .{ .status = status, .payload = if (status == abi.Status.ok) try fixed(allocator, info) else &.{}, .allocator = allocator };
        },
        .asset_read => return readBuffer(allocator, api.asset_read, api.context, request.id),
        .asset_open_external => {
            if (payload.len == 0) return error.InvalidRpcPayload;
            var handle: u64 = 0;
            const status = api.asset_open_external(api.context, slice(payload), &handle);
            return .{ .status = status, .value = handle };
        },
        .source_read => {
            if (request.id != 0) return error.InvalidRpcPayload;
            if (!api.isCurrent()) return .{ .status = abi.Status.abi_mismatch };
            const value = protocol.parseSourceRead(payload) catch return error.InvalidRpcPayload;
            return readSource(allocator, api, value);
        },
        .shell_handshake, .shell_commit, .input_begin, .input_end, .jobs_read => return .{ .status = abi.Status.invalid_state },
        .document_open_external => {
            if (payload.len == 0) return error.InvalidRpcPayload;
            var grant: u64 = 0;
            const grant_status = grant_external(api.context, slice(payload), 1, &grant);
            if (grant_status != abi.Status.ok) return .{ .status = grant_status };
            var uri_buffer: [64]u8 = undefined;
            const uri = try std.fmt.bufPrint(&uri_buffer, "external://{d}", .{grant});
            return .{ .status = api.command_result(api.context, slice("doc.open"), slice(uri), null), .value = grant };
        },
    }
}

const WorkspaceMock = struct {
    revision: u64 = 1,
    mutate_after_query: bool = false,
    submits: usize = 0,

    fn api(self: *WorkspaceMock) workspace.Api {
        return .{ .context = self, .snapshot = snapshot, .submit = submit };
    }

    fn shellApi(self: *WorkspaceMock) abi.ShellApi {
        var value: abi.ShellApi = undefined;
        value.context = self;
        value.workspace_api = getApi;
        return value;
    }

    fn getApi(ptr: ?*anyopaque, out: ?*workspace.Api) callconv(.c) i32 {
        const self: *WorkspaceMock = @ptrCast(@alignCast(ptr.?));
        out.?.* = self.api();
        return abi.Status.ok;
    }

    fn noGrant(_: ?*anyopaque, _: abi.ByteSlice, _: u32, _: ?*u64) callconv(.c) i32 {
        return abi.Status.invalid_state;
    }

    fn snapshot(ptr: ?*anyopaque, expected: ?*const workspace.Stamp, out: ?*workspace.Snapshot, buffer: ?[*]u8, capacity: usize, out_len: ?*usize) callconv(.c) i32 {
        const self: *WorkspaceMock = @ptrCast(@alignCast(ptr.?));
        const stamp = workspace.Stamp{ .epoch_hi = 11, .epoch_lo = 22, .revision = self.revision };
        if (expected) |value| if (!value.eql(stamp)) return workspace.Status.stale_version;
        const text = "cut";
        out.?.* = .{ .stamp = stamp, .fingerprint = 33, .node_id_high_water = 4, .flags = 1, .text_len = text.len };
        out_len.?.* = text.len;
        if (buffer == null or capacity < text.len) {
            if (self.mutate_after_query) self.revision += 1;
            return abi.Status.buffer_too_small;
        }
        @memcpy(buffer.?[0..text.len], text);
        return abi.Status.ok;
    }

    fn submit(ptr: ?*anyopaque, request: ?*const workspace.Request, out: ?*workspace.Outcome) callconv(.c) i32 {
        const self: *WorkspaceMock = @ptrCast(@alignCast(ptr.?));
        self.submits += 1;
        out.?.* = .{ .status = abi.Status.ok, .disposition = @backingInt(workspace.Disposition.replayed), .sequence = request.?.sequence, .stamp = request.?.expected, .created_id = 7 };
        return abi.Status.ok;
    }
};

const ResourceMock = struct {
    revision: u64 = 0,
    mutate_after_query: bool = false,
    submit_status: i32 = abi.Status.ok,
    submits: usize = 0,
    getters: usize = 0,

    fn shellApi(self: *ResourceMock) abi.ShellApi {
        var value: abi.ShellApi = undefined;
        value.struct_size = @sizeOf(abi.ShellApi);
        value.abi_version = abi.version;
        value.context = self;
        value.resource_api = getApi;
        return value;
    }

    fn getApi(pointer: ?*anyopaque, out: ?*resource.Api) callconv(.c) i32 {
        const self: *ResourceMock = @ptrCast(@alignCast(pointer.?));
        self.getters += 1;
        out.?.* = .{ .context = self, .snapshot = snapshot, .probe = probe, .submit = submit, .work_snapshot = workSnapshotMock, .work_submit = workSubmitMock };
        return abi.Status.ok;
    }

    fn workSnapshotMock(_: ?*anyopaque, _: u64, _: ?*const resource.WorkSnapshot, _: ?*resource.WorkSnapshot, _: ?[*]u8, _: usize, _: ?*usize) callconv(.c) i32 {
        return abi.Status.not_ready;
    }

    fn workSubmitMock(pointer: ?*anyopaque, request: ?*const resource.WorkRequest, out: ?*resource.WorkOutcome) callconv(.c) i32 {
        const self: *ResourceMock = @ptrCast(@alignCast(pointer.?));
        self.submits += 1;
        out.?.* = .{ .status = abi.Status.ok, .disposition = @backingInt(resource.Disposition.replayed), .sequence = request.?.sequence, .stamp = .{ .epoch_hi = 7, .epoch_lo = 8 }, .resource_id = 1, .work_revision = 1, .draft_revision = 0, .content_hash = @splat(0) };
        return abi.Status.ok;
    }

    fn stamp(self: *ResourceMock) resource.Stamp {
        return .{ .epoch_hi = 7, .epoch_lo = 8, .revision = self.revision };
    }

    fn snapshot(pointer: ?*anyopaque, expected: ?*const resource.Stamp, out: ?*resource.Snapshot, buffer: ?[*]u8, capacity: usize, length: ?*usize) callconv(.c) i32 {
        const self: *ResourceMock = @ptrCast(@alignCast(pointer.?));
        length.?.* = 0;
        if (expected) |value| if (!value.eql(self.stamp())) return resource.Status.stale_version;
        const text = "{}";
        out.?.* = .{ .stamp = self.stamp(), .text_len = text.len };
        length.?.* = text.len;
        if (buffer == null or capacity < text.len) {
            if (self.mutate_after_query) self.revision += 1;
            return abi.Status.buffer_too_small;
        }
        @memcpy(buffer.?[0..text.len], text);
        return abi.Status.ok;
    }

    fn probe(_: ?*anyopaque, request: ?*const resource.ProbeRequest, out: ?*resource.Proof) callconv(.c) i32 {
        const value = request.?;
        out.?.* = .{ .stamp = value.expected, .target_id = value.target_id, .mode = value.mode, .head_hash = @splat(1), .content_hash = @splat(2), .path_hash = @splat(3), .byte_length = 4, .volume_serial = 5, .file_index = 6 };
        return abi.Status.ok;
    }

    fn submit(pointer: ?*anyopaque, request: ?*const resource.Request, out: ?*resource.Outcome) callconv(.c) i32 {
        const self: *ResourceMock = @ptrCast(@alignCast(pointer.?));
        self.submits += 1;
        if (self.submit_status != abi.Status.ok) return self.submit_status;
        out.?.* = .{ .status = resource.Status.candidate_changed, .disposition = @backingInt(resource.Disposition.rejected), .sequence = request.?.sequence, .stamp = self.stamp(), .resource_id = request.?.proof.target_id };
        return abi.Status.ok;
    }
};

test "resource Host snapshot is coherent at revision zero and rejects old ABI tables" {
    var mock: ResourceMock = .{};
    var api = mock.shellApi();
    var packet: [resource_wire.snapshot_request_size]u8 = undefined;
    const bytes = try resource_wire.writeSnapshotRequest(&packet, null);
    const request = protocol.Request{ .kind = .resource_snapshot, .payload_len = @intCast(bytes.len) };
    var reply = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, request, bytes);
    defer reply.deinit();
    try std.testing.expectEqual(abi.Status.ok, reply.status);
    const metadata = try resource_wire.readSnapshot(reply.payload[0..resource_wire.snapshot_size]);
    try std.testing.expectEqual(@as(u64, 0), metadata.stamp.revision);
    try std.testing.expectEqualStrings("{}", reply.payload[resource_wire.snapshot_size..]);
    mock.mutate_after_query = true;
    var stale = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, request, bytes);
    defer stale.deinit();
    try std.testing.expectEqual(resource.Status.stale_version, stale.status);
    try std.testing.expectEqual(@as(usize, 0), stale.payload.len);
    const getters = mock.getters;
    api.struct_size = @offsetOf(abi.ShellApi, "resource_api");
    var old = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, request, bytes);
    defer old.deinit();
    try std.testing.expectEqual(abi.Status.abi_mismatch, old.status);
    try std.testing.expectEqual(getters, mock.getters);
}

test "Host transports preview info and pixels without Shell struct coupling" {
    const Mock = struct {
        fn shellApi(self: *@This()) abi.ShellApi {
            var value: abi.ShellApi = undefined;
            value.context = self;
            value.preview_info = info;
            value.preview_read = read;
            return value;
        }
        fn info(_: ?*anyopaque, expected: u64, out: ?*abi.PreviewInfo) callconv(.c) i32 {
            if (expected != 41) return abi.Status.invalid_state;
            out.?.* = .{ .struct_size = @sizeOf(abi.PreviewInfo), .abi_version = @import("vne").preview.version, .width = 2, .height = 1, .format = @intFromEnum(@import("vne").preview.Format.bgra8), .generation = 3, .fingerprint = 41, .epoch_hi = 1, .epoch_lo = 2, .revision = 1, .bytes_len = 8 };
            return abi.Status.ok;
        }
        fn read(_: ?*anyopaque, expected: u64, buffer: ?[*]u8, capacity: usize, out_len: ?*usize) callconv(.c) i32 {
            if (expected != 41) return abi.Status.invalid_state;
            out_len.?.* = 8;
            if (buffer == null or capacity < 8) return abi.Status.buffer_too_small;
            @memcpy(buffer.?[0..8], "BGRA0000");
            return abi.Status.ok;
        }
    };
    var mock: Mock = .{};
    var api = mock.shellApi();
    var frame_payload: [8]u8 = undefined;
    std.mem.writeInt(u64, &frame_payload, 41, .little);
    var info_reply = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, .{ .kind = .preview_info, .payload_len = 8 }, &frame_payload);
    defer info_reply.deinit();
    try std.testing.expectEqual(abi.Status.ok, info_reply.status);
    try std.testing.expectEqual(@as(usize, @sizeOf(abi.PreviewInfo)), info_reply.payload.len);
    var pixels_reply = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, .{ .kind = .preview_read, .payload_len = 8 }, &frame_payload);
    defer pixels_reply.deinit();
    try std.testing.expectEqual(abi.Status.ok, pixels_reply.status);
    try std.testing.expectEqualSlices(u8, "BGRA0000", pixels_reply.payload);
    std.mem.writeInt(u64, &frame_payload, 42, .little);
    var stale = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, .{ .kind = .preview_info, .payload_len = 8 }, &frame_payload);
    defer stale.deinit();
    try std.testing.expectEqual(abi.Status.invalid_state, stale.status);
    const scoped_old = [_]u8{ 41, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0 };
    var old_epoch = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, .{ .kind = .preview_info, .payload_len = 24 }, &scoped_old);
    defer old_epoch.deinit();
    try std.testing.expectEqual(abi.Status.invalid_state, old_epoch.status);
    const scoped_current = [_]u8{ 41, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0 };
    var current_epoch = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, .{ .kind = .preview_info, .payload_len = 24 }, &scoped_current);
    defer current_epoch.deinit();
    try std.testing.expectEqual(abi.Status.ok, current_epoch.status);
}

test "resource Host transports fixed proofs and separates known refusal from unknown submit" {
    var mock: ResourceMock = .{};
    const api = mock.shellApi();
    const path = "C:/owned-fixture/candidate.png";
    const probe = resource.ProbeRequest{ .expected = mock.stamp(), .target_id = 19, .mode = 1, .path = .{ .ptr = path.ptr, .len = path.len } };
    const probe_bytes = try resource_wire.encodeProbeRequest(std.testing.allocator, &probe);
    defer std.testing.allocator.free(probe_bytes);
    var observed = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, .{ .kind = .resource_probe, .payload_len = @intCast(probe_bytes.len) }, probe_bytes);
    defer observed.deinit();
    const proof = try resource_wire.readProof(observed.payload);
    try std.testing.expectEqual(@as(u64, 19), proof.target_id);
    const request = resource.Request{ .client_hi = 1, .client_lo = 2, .sequence = 3, .proof = proof, .path = probe.path };
    const bytes = try resource_wire.encodeRequest(std.testing.allocator, &request);
    defer std.testing.allocator.free(bytes);
    const frame = protocol.Request{ .kind = .resource_submit, .payload_len = @intCast(bytes.len) };
    var known = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, frame, bytes);
    defer known.deinit();
    try std.testing.expectEqual(abi.Status.ok, known.status);
    const outcome = try resource_wire.readOutcome(known.payload);
    try std.testing.expectEqual(resource.Status.candidate_changed, outcome.status);
    try std.testing.expectEqual(request.sequence, outcome.sequence);
    mock.submit_status = abi.Status.failed;
    var unknown = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, frame, bytes);
    defer unknown.deinit();
    try std.testing.expectEqual(abi.Status.failed, unknown.status);
    try std.testing.expectEqual(@as(usize, 0), unknown.payload.len);
    try std.testing.expectEqual(@as(usize, 2), mock.submits);
}

test "workspace Host snapshot never combines different revisions" {
    var mock: WorkspaceMock = .{};
    const api = mock.shellApi();
    var packet: [workspace_wire.snapshot_request_size]u8 = undefined;
    const bytes = try workspace_wire.writeSnapshotRequest(&packet, null);
    const request = protocol.Request{ .kind = .workspace_snapshot, .payload_len = @intCast(bytes.len) };
    var reply = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, request, bytes);
    defer reply.deinit();
    try std.testing.expectEqual(abi.Status.ok, reply.status);
    const metadata = try workspace_wire.readSnapshot(reply.payload[0..workspace_wire.snapshot_size]);
    try std.testing.expectEqual(mock.revision, metadata.stamp.revision);
    try std.testing.expectEqualStrings("cut", reply.payload[workspace_wire.snapshot_size..]);
    mock.mutate_after_query = true;
    var rejected = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, request, bytes);
    defer rejected.deinit();
    try std.testing.expectEqual(workspace.Status.stale_version, rejected.status);
    try std.testing.expectEqual(@as(usize, 0), rejected.payload.len);
}

test "workspace Host transport preserves the original request and known receipt" {
    var mock: WorkspaceMock = .{};
    const api = mock.shellApi();
    const name = "editor.invert.add";
    const request = workspace.Request{ .client_hi = 1, .client_lo = 2, .sequence = 3, .expected = .{ .epoch_hi = 4, .epoch_lo = 5, .revision = 6 }, .name = .{ .ptr = name.ptr, .len = name.len } };
    const bytes = try workspace_wire.encodeRequest(std.testing.allocator, &request);
    defer std.testing.allocator.free(bytes);
    var reply = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, .{ .kind = .workspace_submit, .payload_len = @intCast(bytes.len) }, bytes);
    defer reply.deinit();
    try std.testing.expectEqual(abi.Status.ok, reply.status);
    const outcome = try workspace_wire.readOutcome(reply.payload);
    try std.testing.expectEqual(request.sequence, outcome.sequence);
    try std.testing.expect(outcome.stamp.eql(request.expected));
    try std.testing.expectEqual(@as(u64, 7), outcome.created_id);
    try std.testing.expectEqual(@as(usize, 1), mock.submits);
}

test "Host source reading enforces table tail framing and never publishes a failed read" {
    const Mock = struct {
        calls: usize = 0,
        status: i32 = abi.Status.ok,
        fn read(ptr: ?*anyopaque, uri: abi.ByteSlice, expected: abi.ByteSlice, buffer: ?[*]u8, capacity: usize, out: ?*usize) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.calls += 1;
            out.?.* = 0;
            if (!std.mem.eql(u8, uri.ptr.?[0..uri.len], "library://9") or expected.len != 64) return abi.Status.invalid_arguments;
            if (buffer == null) {
                out.?.* = 4;
                return abi.Status.buffer_too_small;
            }
            if (self.status != abi.Status.ok) return self.status;
            out.?.* = 4;
            if (capacity < 4) return abi.Status.buffer_too_small;
            @memcpy(buffer.?[0..4], "data");
            return abi.Status.ok;
        }
    };
    var mock: Mock = .{};
    var api: abi.ShellApi = undefined;
    api.struct_size = @sizeOf(abi.ShellApi);
    api.abi_version = abi.version;
    api.context = &mock;
    api.source_read = Mock.read;
    const bytes = try protocol.encodeSourceRead(std.testing.allocator, "library://9", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    defer std.testing.allocator.free(bytes);
    const request = protocol.Request{ .kind = .source_read, .payload_len = @intCast(bytes.len) };
    var reply = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, request, bytes);
    defer reply.deinit();
    try std.testing.expectEqual(abi.Status.ok, reply.status);
    try std.testing.expectEqual(@as(u64, 0), reply.value);
    try std.testing.expectEqualStrings("data", reply.payload);
    mock.status = abi.Status.failed;
    var refused = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, request, bytes);
    defer refused.deinit();
    try std.testing.expectEqual(abi.Status.failed, refused.status);
    try std.testing.expectEqual(@as(u64, 0), refused.value);
    try std.testing.expectEqual(@as(usize, 0), refused.payload.len);
    api.struct_size = @offsetOf(abi.ShellApi, "source_read");
    var old = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, request, bytes);
    defer old.deinit();
    try std.testing.expectEqual(abi.Status.abi_mismatch, old.status);
    try std.testing.expectEqual(@as(usize, 4), mock.calls);
    api.struct_size = @sizeOf(abi.ShellApi);
    bytes[12] = 1;
    try std.testing.expectError(error.InvalidRpcPayload, call(std.testing.allocator, &api, WorkspaceMock.noGrant, request, bytes));
    try std.testing.expectEqual(@as(usize, 4), mock.calls);
}

test "work Host accepts the Python request and returns its fixed outcome" {
    const hex = "600000000400000001d300000000000002d3000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000d000000000000000800000000000000686f73742d6e6f74652e747874686f7374206f6c64";
    var bytes: [101]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);
    var mock: ResourceMock = .{};
    const api = mock.shellApi();
    var reply = try call(std.testing.allocator, &api, WorkspaceMock.noGrant, .{ .kind = .work_submit, .payload_len = bytes.len }, &bytes);
    defer reply.deinit();
    try std.testing.expectEqual(abi.Status.ok, reply.status);
    const outcome = try protocol.work_wire.readOutcome(reply.payload);
    try std.testing.expectEqual(@as(u64, 1), outcome.sequence);
    try std.testing.expectEqual(@as(u64, 1), outcome.resource_id);
    try std.testing.expectEqual(@as(u64, 1), outcome.work_revision);
}
