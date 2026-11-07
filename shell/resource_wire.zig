//! Pointer-free, fixed-width little-endian Resource API v2 pipe encoding.
const std = @import("std");
const resource = @import("vne").resource_api;

pub const snapshot_request_size = 32;
pub const snapshot_size = 40;
pub const proof_size = 168;
pub const probe_header_size = 48;
pub const request_header_size = 208;
pub const outcome_size = 56;

fn stampWrite(bytes: []u8, value: resource.Stamp) void {
    std.mem.writeInt(u64, bytes[0..8], value.epoch_hi, .little);
    std.mem.writeInt(u64, bytes[8..16], value.epoch_lo, .little);
    std.mem.writeInt(u64, bytes[16..24], value.revision, .little);
}

fn stampRead(bytes: []const u8) resource.Stamp {
    return .{
        .epoch_hi = std.mem.readInt(u64, bytes[0..8], .little),
        .epoch_lo = std.mem.readInt(u64, bytes[8..16], .little),
        .revision = std.mem.readInt(u64, bytes[16..24], .little),
    };
}

fn validHeader(bytes: []const u8, length: usize) bool {
    return bytes.len == length and std.mem.readInt(u32, bytes[0..4], .little) == resource.version;
}

pub fn writeSnapshotRequest(buffer: []u8, expected: ?*const resource.Stamp) ![]const u8 {
    if (buffer.len < snapshot_request_size) return error.InvalidResourceWire;
    const bytes = buffer[0..snapshot_request_size];
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], resource.version, .little);
    if (expected) |value| {
        std.mem.writeInt(u32, bytes[4..8], 1, .little);
        stampWrite(bytes[8..32], value.*);
    }
    return bytes;
}

pub fn readSnapshotRequest(bytes: []const u8) !?resource.Stamp {
    if (!validHeader(bytes, snapshot_request_size)) return error.InvalidResourceWire;
    const value = stampRead(bytes[8..32]);
    return switch (std.mem.readInt(u32, bytes[4..8], .little)) {
        0 => if (value.eql(.{})) null else error.InvalidResourceWire,
        1 => value,
        else => error.InvalidResourceWire,
    };
}

fn pathBytes(value: resource.Bytes) ![]const u8 {
    if (value.len == 0 or value.len > resource.max_path_size) return error.InvalidResourceWire;
    const pointer = value.ptr orelse return error.InvalidResourceWire;
    const path = pointer[0..value.len];
    if (!resource.validPath(path)) return error.InvalidResourceWire;
    return path;
}

pub fn encodeProbeRequest(allocator: std.mem.Allocator, value: *const resource.ProbeRequest) ![]u8 {
    if (value.struct_size != @sizeOf(resource.ProbeRequest) or value.api_version != resource.version or
        value.reserved != 0 or std.enums.fromInt(resource.Mode, value.mode) == null) return error.InvalidResourceWire;
    const path = try pathBytes(value.path);
    const bytes = try allocator.alloc(u8, probe_header_size + path.len);
    @memset(bytes[0..probe_header_size], 0);
    std.mem.writeInt(u32, bytes[0..4], resource.version, .little);
    std.mem.writeInt(u32, bytes[4..8], value.mode, .little);
    stampWrite(bytes[8..32], value.expected);
    std.mem.writeInt(u64, bytes[32..40], value.target_id, .little);
    std.mem.writeInt(u32, bytes[40..44], @intCast(path.len), .little);
    @memcpy(bytes[probe_header_size..], path);
    return bytes;
}

/// Path slices borrow this packet until the synchronous API call finishes.
pub fn readProbeRequest(bytes: []const u8) !resource.ProbeRequest {
    if (bytes.len < probe_header_size or std.mem.readInt(u32, bytes[0..4], .little) != resource.version or
        std.mem.readInt(u32, bytes[44..48], .little) != 0) return error.InvalidResourceWire;
    const mode = std.mem.readInt(u32, bytes[4..8], .little);
    const length: usize = std.mem.readInt(u32, bytes[40..44], .little);
    if (std.enums.fromInt(resource.Mode, mode) == null or length == 0 or length > resource.max_path_size or
        bytes.len != probe_header_size + length or !resource.validPath(bytes[probe_header_size..])) return error.InvalidResourceWire;
    return .{ .expected = stampRead(bytes[8..32]), .target_id = std.mem.readInt(u64, bytes[32..40], .little), .mode = mode, .path = .{ .ptr = bytes[probe_header_size..].ptr, .len = length } };
}

pub fn writeProof(buffer: []u8, value: resource.Proof) ![]const u8 {
    if (buffer.len < proof_size or !resource.validProof(&value)) return error.InvalidResourceWire;
    const bytes = buffer[0..proof_size];
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], resource.version, .little);
    stampWrite(bytes[8..32], value.stamp);
    std.mem.writeInt(u64, bytes[32..40], value.target_id, .little);
    std.mem.writeInt(u32, bytes[40..44], value.mode, .little);
    @memcpy(bytes[48..80], &value.head_hash);
    @memcpy(bytes[80..112], &value.content_hash);
    @memcpy(bytes[112..144], &value.path_hash);
    std.mem.writeInt(u64, bytes[144..152], value.byte_length, .little);
    std.mem.writeInt(u64, bytes[152..160], value.volume_serial, .little);
    std.mem.writeInt(u64, bytes[160..168], value.file_index, .little);
    return bytes;
}

pub fn readProof(bytes: []const u8) !resource.Proof {
    if (!validHeader(bytes, proof_size) or std.mem.readInt(u32, bytes[4..8], .little) != 0 or
        std.mem.readInt(u32, bytes[44..48], .little) != 0) return error.InvalidResourceWire;
    const value = resource.Proof{ .stamp = stampRead(bytes[8..32]), .target_id = std.mem.readInt(u64, bytes[32..40], .little), .mode = std.mem.readInt(u32, bytes[40..44], .little), .head_hash = bytes[48..80].*, .content_hash = bytes[80..112].*, .path_hash = bytes[112..144].*, .byte_length = std.mem.readInt(u64, bytes[144..152], .little), .volume_serial = std.mem.readInt(u64, bytes[152..160], .little), .file_index = std.mem.readInt(u64, bytes[160..168], .little) };
    if (!resource.validProof(&value)) return error.InvalidResourceWire;
    return value;
}

pub fn encodeRequest(allocator: std.mem.Allocator, value: *const resource.Request) ![]u8 {
    if (value.struct_size != @sizeOf(resource.Request) or value.api_version != resource.version or
        !resource.validProof(&value.proof)) return error.InvalidResourceWire;
    const path = try pathBytes(value.path);
    const bytes = try allocator.alloc(u8, request_header_size + path.len);
    errdefer allocator.free(bytes);
    @memset(bytes[0..request_header_size], 0);
    std.mem.writeInt(u32, bytes[0..4], resource.version, .little);
    std.mem.writeInt(u64, bytes[8..16], value.client_hi, .little);
    std.mem.writeInt(u64, bytes[16..24], value.client_lo, .little);
    std.mem.writeInt(u64, bytes[24..32], value.sequence, .little);
    _ = try writeProof(bytes[32..200], value.proof);
    std.mem.writeInt(u32, bytes[200..204], @intCast(path.len), .little);
    @memcpy(bytes[request_header_size..], path);
    return bytes;
}

pub fn readRequest(bytes: []const u8) !resource.Request {
    if (bytes.len < request_header_size or std.mem.readInt(u32, bytes[0..4], .little) != resource.version or
        std.mem.readInt(u32, bytes[4..8], .little) != 0 or std.mem.readInt(u32, bytes[204..208], .little) != 0) return error.InvalidResourceWire;
    const length: usize = std.mem.readInt(u32, bytes[200..204], .little);
    if (length == 0 or length > resource.max_path_size or bytes.len != request_header_size + length or
        !resource.validPath(bytes[request_header_size..])) return error.InvalidResourceWire;
    return .{ .client_hi = std.mem.readInt(u64, bytes[8..16], .little), .client_lo = std.mem.readInt(u64, bytes[16..24], .little), .sequence = std.mem.readInt(u64, bytes[24..32], .little), .proof = try readProof(bytes[32..200]), .path = .{ .ptr = bytes[request_header_size..].ptr, .len = length } };
}

pub fn writeSnapshot(buffer: []u8, value: resource.Snapshot) ![]const u8 {
    if (buffer.len < snapshot_size or value.struct_size != @sizeOf(resource.Snapshot) or value.api_version != resource.version) return error.InvalidResourceWire;
    const bytes = buffer[0..snapshot_size];
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], resource.version, .little);
    stampWrite(bytes[8..32], value.stamp);
    std.mem.writeInt(u64, bytes[32..40], @intCast(value.text_len), .little);
    return bytes;
}

pub fn readSnapshot(bytes: []const u8) !resource.Snapshot {
    if (!validHeader(bytes, snapshot_size) or std.mem.readInt(u32, bytes[4..8], .little) != 0) return error.InvalidResourceWire;
    return .{ .stamp = stampRead(bytes[8..32]), .text_len = std.math.cast(usize, std.mem.readInt(u64, bytes[32..40], .little)) orelse return error.InvalidResourceWire };
}

pub fn writeOutcome(buffer: []u8, value: resource.Outcome) ![]const u8 {
    if (buffer.len < outcome_size or value.struct_size != @sizeOf(resource.Outcome) or value.api_version != resource.version or
        std.enums.fromInt(resource.Disposition, value.disposition) == null) return error.InvalidResourceWire;
    const bytes = buffer[0..outcome_size];
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], resource.version, .little);
    std.mem.writeInt(i32, bytes[4..8], value.status, .little);
    std.mem.writeInt(u32, bytes[8..12], value.disposition, .little);
    std.mem.writeInt(u64, bytes[16..24], value.sequence, .little);
    stampWrite(bytes[24..48], value.stamp);
    std.mem.writeInt(u64, bytes[48..56], value.resource_id, .little);
    return bytes;
}

pub fn readOutcome(bytes: []const u8) !resource.Outcome {
    if (!validHeader(bytes, outcome_size) or std.mem.readInt(u32, bytes[12..16], .little) != 0) return error.InvalidResourceWire;
    const disposition = std.mem.readInt(u32, bytes[8..12], .little);
    if (std.enums.fromInt(resource.Disposition, disposition) == null) return error.InvalidResourceWire;
    return .{ .status = std.mem.readInt(i32, bytes[4..8], .little), .disposition = disposition, .sequence = std.mem.readInt(u64, bytes[16..24], .little), .stamp = stampRead(bytes[24..48]), .resource_id = std.mem.readInt(u64, bytes[48..56], .little) };
}

test "resource wire preserves proof identity and exact path without pointers" {
    const path = "C:/owned-fixture/candidate.png";
    const probe = resource.ProbeRequest{ .expected = .{ .epoch_hi = 1, .epoch_lo = 2 }, .target_id = 3, .mode = @backingInt(resource.Mode.adopt), .path = .{ .ptr = path.ptr, .len = path.len } };
    const probe_bytes = try encodeProbeRequest(std.testing.allocator, &probe);
    defer std.testing.allocator.free(probe_bytes);
    const decoded_probe = try readProbeRequest(probe_bytes);
    try std.testing.expect(decoded_probe.expected.eql(probe.expected));
    try std.testing.expectEqualStrings(path, decoded_probe.path.ptr.?[0..decoded_probe.path.len]);
    const proof = resource.Proof{ .stamp = probe.expected, .target_id = 3, .mode = probe.mode, .head_hash = @splat(1), .content_hash = @splat(2), .path_hash = @splat(3), .byte_length = 123, .volume_serial = 0xaabbccdd, .file_index = 0x1122334455667788 };
    const request = resource.Request{ .client_hi = 4, .client_lo = 5, .sequence = 6, .proof = proof, .path = probe.path };
    const bytes = try encodeRequest(std.testing.allocator, &request);
    defer std.testing.allocator.free(bytes);
    const decoded = try readRequest(bytes);
    try std.testing.expectEqual(request.sequence, decoded.sequence);
    try std.testing.expectEqualDeep(proof, decoded.proof);
    try std.testing.expectEqualStrings(path, decoded.path.ptr.?[0..decoded.path.len]);
    bytes[204] = 1;
    try std.testing.expectError(error.InvalidResourceWire, readRequest(bytes));
    probe_bytes[47] = 1;
    try std.testing.expectError(error.InvalidResourceWire, readProbeRequest(probe_bytes));
}

test "resource wire rejects oversized paths and mismatched struct versions" {
    const path = try std.testing.allocator.alloc(u8, resource.max_path_size + 1);
    defer std.testing.allocator.free(path);
    @memset(path, 'a');
    var probe = resource.ProbeRequest{ .expected = .{}, .target_id = 1, .mode = 1, .path = .{ .ptr = path.ptr, .len = path.len } };
    try std.testing.expectError(error.InvalidResourceWire, encodeProbeRequest(std.testing.allocator, &probe));
    probe.path = .{ .ptr = "C:/a".ptr, .len = 4 };
    probe.struct_size -= 1;
    try std.testing.expectError(error.InvalidResourceWire, encodeProbeRequest(std.testing.allocator, &probe));
    var bytes: [snapshot_request_size]u8 = undefined;
    _ = try writeSnapshotRequest(&bytes, null);
    bytes[8] = 1;
    try std.testing.expectError(error.InvalidResourceWire, readSnapshotRequest(&bytes));
}
