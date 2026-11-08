//! Pointer-free Resource API v3 working-body transport.
const std = @import("std");
const resource = @import("vne").resource_api;

pub const snapshot_size = 144;
pub const outcome_size = 104;
pub const request_header_size = 80;

pub const DecodedRequest = struct {
    value: resource.WorkRequest,
    label: []const u8,
    body: []const u8,
};

fn put(bytes: []u8, at: usize, value: anytype) void {
    const T = @TypeOf(value);
    if (T == u32) std.mem.writeInt(u32, bytes[at..][0..4], value, .little) else if (T == i32)
        std.mem.writeInt(i32, bytes[at..][0..4], value, .little)
    else if (T == u64)
        std.mem.writeInt(u64, bytes[at..][0..8], value, .little)
    else if (T == usize)
        std.mem.writeInt(u64, bytes[at..][0..8], @intCast(value), .little)
    else
        @compileError("unsupported work wire integer");
}

fn get(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

fn stamp(bytes: []u8, at: usize, value: resource.Stamp) void {
    put(bytes, at, value.epoch_hi);
    put(bytes, at + 8, value.epoch_lo);
    put(bytes, at + 16, value.revision);
}

fn readStamp(bytes: []const u8, at: usize) resource.Stamp {
    return .{ .epoch_hi = get(u64, bytes, at), .epoch_lo = get(u64, bytes, at + 8), .revision = get(u64, bytes, at + 16) };
}

pub fn writeSnapshot(bytes: []u8, value: resource.WorkSnapshot) ![]const u8 {
    if (bytes.len < snapshot_size or value.struct_size != @sizeOf(resource.WorkSnapshot) or value.api_version != resource.version or value.reserved != 0) return error.InvalidWorkSnapshot;
    @memset(bytes[0..snapshot_size], 0);
    put(bytes, 0, value.struct_size);
    put(bytes, 4, value.api_version);
    stamp(bytes, 8, value.stamp);
    put(bytes, 32, value.resource_id);
    put(bytes, 40, value.work_revision);
    put(bytes, 48, value.base_revision);
    put(bytes, 56, value.draft_revision);
    put(bytes, 64, value.body_origin);
    @memcpy(bytes[72..104], &value.content_hash);
    @memcpy(bytes[104..136], &value.body_hash);
    put(bytes, 136, value.body_len);
    return bytes[0..snapshot_size];
}

pub fn readSnapshot(bytes: []const u8) !resource.WorkSnapshot {
    if (bytes.len != snapshot_size or get(u32, bytes, 0) != @sizeOf(resource.WorkSnapshot) or
        get(u32, bytes, 4) != resource.version or get(u32, bytes, 68) != 0 or
        std.enums.fromInt(resource.WorkBody, get(u32, bytes, 64)) == null) return error.InvalidWorkSnapshot;
    const value = resource.WorkSnapshot{
        .stamp = readStamp(bytes, 8),
        .resource_id = get(u64, bytes, 32),
        .work_revision = get(u64, bytes, 40),
        .base_revision = get(u64, bytes, 48),
        .draft_revision = get(u64, bytes, 56),
        .body_origin = get(u32, bytes, 64),
        .content_hash = bytes[72..104].*,
        .body_hash = bytes[104..136].*,
        .body_len = get(usize, bytes, 136),
    };
    if (value.resource_id == 0 or value.work_revision == 0 or value.base_revision == 0 or value.base_revision > value.work_revision) return error.InvalidWorkSnapshot;
    if (value.body_origin == @backingInt(resource.WorkBody.draft)) {
        if (value.draft_revision == 0) return error.InvalidWorkSnapshot;
    } else if (value.draft_revision != 0) return error.InvalidWorkSnapshot;
    return value;
}

pub fn writeOutcome(bytes: []u8, value: resource.WorkOutcome) ![]const u8 {
    if (bytes.len < outcome_size or value.struct_size != @sizeOf(resource.WorkOutcome) or value.api_version != resource.version or
        std.enums.fromInt(resource.Disposition, value.disposition) == null) return error.InvalidWorkOutcome;
    @memset(bytes[0..outcome_size], 0);
    put(bytes, 0, value.struct_size);
    put(bytes, 4, value.api_version);
    put(bytes, 8, value.status);
    put(bytes, 12, value.disposition);
    put(bytes, 16, value.sequence);
    stamp(bytes, 24, value.stamp);
    put(bytes, 48, value.resource_id);
    put(bytes, 56, value.work_revision);
    put(bytes, 64, value.draft_revision);
    @memcpy(bytes[72..104], &value.content_hash);
    return bytes[0..outcome_size];
}

pub fn readOutcome(bytes: []const u8) !resource.WorkOutcome {
    if (bytes.len != outcome_size or get(u32, bytes, 0) != @sizeOf(resource.WorkOutcome) or
        get(u32, bytes, 4) != resource.version or std.enums.fromInt(resource.Disposition, get(u32, bytes, 12)) == null) return error.InvalidWorkOutcome;
    return .{
        .status = get(i32, bytes, 8),
        .disposition = get(u32, bytes, 12),
        .sequence = get(u64, bytes, 16),
        .stamp = readStamp(bytes, 24),
        .resource_id = get(u64, bytes, 48),
        .work_revision = get(u64, bytes, 56),
        .draft_revision = get(u64, bytes, 64),
        .content_hash = bytes[72..104].*,
    };
}

pub fn encodeRequest(allocator: std.mem.Allocator, value: *const resource.WorkRequest, label: []const u8, body: []const u8) ![]u8 {
    if (!resource.validWorkRequest(value) or label.len != value.label.len or body.len != value.body.len) return error.InvalidWorkRequest;
    const bytes = try allocator.alloc(u8, request_header_size + label.len + body.len);
    @memset(bytes[0..request_header_size], 0);
    put(bytes, 0, value.struct_size);
    put(bytes, 4, value.api_version);
    put(bytes, 8, value.client_hi);
    put(bytes, 16, value.client_lo);
    put(bytes, 24, value.sequence);
    put(bytes, 32, value.resource_id);
    put(bytes, 40, value.base_revision);
    put(bytes, 48, value.expected_draft_revision);
    put(bytes, 56, value.mode);
    put(bytes, 64, label.len);
    put(bytes, 72, body.len);
    @memcpy(bytes[request_header_size..][0..label.len], label);
    @memcpy(bytes[request_header_size + label.len ..], body);
    return bytes;
}

pub fn readRequest(bytes: []const u8) !DecodedRequest {
    if (bytes.len < request_header_size or get(u32, bytes, 0) != @sizeOf(resource.WorkRequest) or
        get(u32, bytes, 4) != resource.version or get(u32, bytes, 60) != 0) return error.InvalidWorkRequest;
    const label_len = get(usize, bytes, 64);
    const body_len = get(usize, bytes, 72);
    if (label_len > resource.max_work_label_size or body_len > resource.max_work_body_size or
        bytes.len != request_header_size + label_len + body_len) return error.InvalidWorkRequest;
    const label = bytes[request_header_size..][0..label_len];
    const body = bytes[request_header_size + label_len ..];
    const value = resource.WorkRequest{
        .client_hi = get(u64, bytes, 8),
        .client_lo = get(u64, bytes, 16),
        .sequence = get(u64, bytes, 24),
        .resource_id = get(u64, bytes, 32),
        .base_revision = get(u64, bytes, 40),
        .expected_draft_revision = get(u64, bytes, 48),
        .mode = get(u32, bytes, 56),
        .label = .{ .ptr = if (label.len == 0) null else label.ptr, .len = label.len },
        .body = .{ .ptr = if (body.len == 0) null else body.ptr, .len = body.len },
    };
    if (!resource.validWorkRequest(&value)) return error.InvalidWorkRequest;
    return .{ .value = value, .label = label, .body = body };
}

test "work wire preserves empty and binary bodies without transporting pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const label = "note.txt";
    const body = [_]u8{ 0, 1, 2, 255 };
    const value = resource.WorkRequest{ .client_hi = 1, .client_lo = 2, .sequence = 3, .mode = @backingInt(resource.WorkMode.create), .label = .{ .ptr = label.ptr, .len = label.len }, .body = .{ .ptr = &body, .len = body.len } };
    const encoded = try encodeRequest(allocator, &value, label, &body);
    const decoded = try readRequest(encoded);
    try std.testing.expectEqualStrings(label, decoded.label);
    try std.testing.expectEqualSlices(u8, &body, decoded.body);
    try std.testing.expect(decoded.value.body.ptr != value.body.ptr);
    encoded[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidWorkRequest, readRequest(encoded[0 .. encoded.len - 1]));
}

test "work snapshots and outcomes reject truncation and stale versions" {
    var snapshot = resource.WorkSnapshot{ .stamp = .{ .epoch_hi = 1, .epoch_lo = 2, .revision = 3 }, .resource_id = 4, .work_revision = 2, .base_revision = 1, .draft_revision = 9, .body_origin = @backingInt(resource.WorkBody.draft), .content_hash = @splat(5), .body_hash = @splat(6), .body_len = 7 };
    var buffer: [snapshot_size]u8 = undefined;
    _ = try writeSnapshot(&buffer, snapshot);
    try std.testing.expectEqualDeep(snapshot, try readSnapshot(&buffer));
    buffer[4] = 2;
    try std.testing.expectError(error.InvalidWorkSnapshot, readSnapshot(&buffer));
    buffer[4] = resource.version;
    snapshot.body_origin = @backingInt(resource.WorkBody.published);
    _ = try writeSnapshot(&buffer, snapshot);
    try std.testing.expectError(error.InvalidWorkSnapshot, readSnapshot(&buffer));
    const outcome = resource.WorkOutcome{ .status = 0, .disposition = @backingInt(resource.Disposition.executed), .sequence = 3, .stamp = .{ .epoch_hi = 1, .epoch_lo = 2 }, .resource_id = 4, .work_revision = 2, .draft_revision = 0, .content_hash = @splat(5) };
    var encoded: [outcome_size]u8 = undefined;
    _ = try writeOutcome(&encoded, outcome);
    try std.testing.expectEqualDeep(outcome, try readOutcome(&encoded));
    try std.testing.expectError(error.InvalidWorkOutcome, readOutcome(encoded[0 .. outcome_size - 1]));
}

test "Python Host fixture is a valid pointer-free work request" {
    const hex = "600000000300000001d300000000000002d3000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000d000000000000000800000000000000686f73742d6e6f74652e747874686f7374206f6c64";
    var bytes: [101]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);
    const decoded = try readRequest(&bytes);
    try std.testing.expectEqualStrings("host-note.txt", decoded.label);
    try std.testing.expectEqualStrings("host old", decoded.body);
}
