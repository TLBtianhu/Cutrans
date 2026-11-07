//! Pointer-free little-endian encoding for Workspace API v1 over the Host pipe.
const std = @import("std");
const workspace = @import("vne").workspace;

pub const snapshot_request_size = 32;
pub const snapshot_size = 64;
pub const outcome_size = 64;
pub const request_header_size = 64;
pub const max_string_size = 1024 * 1024;

fn stampWrite(bytes: []u8, value: workspace.Stamp) void {
    std.mem.writeInt(u64, bytes[0..8], value.epoch_hi, .little);
    std.mem.writeInt(u64, bytes[8..16], value.epoch_lo, .little);
    std.mem.writeInt(u64, bytes[16..24], value.revision, .little);
}

fn stampRead(bytes: []const u8) workspace.Stamp {
    return .{
        .epoch_hi = std.mem.readInt(u64, bytes[0..8], .little),
        .epoch_lo = std.mem.readInt(u64, bytes[8..16], .little),
        .revision = std.mem.readInt(u64, bytes[16..24], .little),
    };
}

pub fn writeSnapshotRequest(buffer: []u8, expected: ?*const workspace.Stamp) ![]const u8 {
    if (buffer.len < snapshot_request_size) return error.InvalidWorkspaceWire;
    const bytes = buffer[0..snapshot_request_size];
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], workspace.version, .little);
    if (expected) |value| {
        std.mem.writeInt(u32, bytes[4..8], 1, .little);
        stampWrite(bytes[8..32], value.*);
    }
    return bytes;
}

pub fn readSnapshotRequest(bytes: []const u8) !?workspace.Stamp {
    if (bytes.len != snapshot_request_size or std.mem.readInt(u32, bytes[0..4], .little) != workspace.version) return error.InvalidWorkspaceWire;
    const present = std.mem.readInt(u32, bytes[4..8], .little);
    const stamp = stampRead(bytes[8..32]);
    return switch (present) {
        0 => if (stamp.eql(.{})) null else error.InvalidWorkspaceWire,
        1 => stamp,
        else => error.InvalidWorkspaceWire,
    };
}

fn inputBytes(value: workspace.Bytes, required: bool) ![]const u8 {
    if (value.len > max_string_size or (required and value.len == 0)) return error.InvalidWorkspaceWire;
    if (value.len == 0) return &.{};
    const ptr = value.ptr orelse return error.InvalidWorkspaceWire;
    return ptr[0..value.len];
}

pub fn encodeRequest(allocator: std.mem.Allocator, value: *const workspace.Request) ![]u8 {
    if (value.struct_size < @sizeOf(workspace.Request) or value.api_version != workspace.version) return error.InvalidWorkspaceWire;
    const name = try inputBytes(value.name, true);
    const arg = try inputBytes(value.arg, false);
    const bytes = try allocator.alloc(u8, request_header_size + name.len + arg.len);
    @memset(bytes[0..request_header_size], 0);
    std.mem.writeInt(u32, bytes[0..4], workspace.version, .little);
    std.mem.writeInt(u32, bytes[4..8], @intFromBool(value.arg.ptr != null), .little);
    std.mem.writeInt(u64, bytes[8..16], value.client_hi, .little);
    std.mem.writeInt(u64, bytes[16..24], value.client_lo, .little);
    std.mem.writeInt(u64, bytes[24..32], value.sequence, .little);
    stampWrite(bytes[32..56], value.expected);
    std.mem.writeInt(u32, bytes[56..60], @intCast(name.len), .little);
    std.mem.writeInt(u32, bytes[60..64], @intCast(arg.len), .little);
    @memcpy(bytes[request_header_size..][0..name.len], name);
    @memcpy(bytes[request_header_size + name.len ..], arg);
    return bytes;
}

/// The decoded byte slices borrow the packet until the synchronous submit returns.
pub fn readRequest(bytes: []const u8) !workspace.Request {
    if (bytes.len < request_header_size or std.mem.readInt(u32, bytes[0..4], .little) != workspace.version) return error.InvalidWorkspaceWire;
    const arg_present = std.mem.readInt(u32, bytes[4..8], .little);
    const name_len: usize = std.mem.readInt(u32, bytes[56..60], .little);
    const arg_len: usize = std.mem.readInt(u32, bytes[60..64], .little);
    if (arg_present > 1 or name_len == 0 or name_len > max_string_size or arg_len > max_string_size or
        (arg_present == 0 and arg_len != 0) or bytes.len != request_header_size + name_len + arg_len) return error.InvalidWorkspaceWire;
    return .{
        .client_hi = std.mem.readInt(u64, bytes[8..16], .little),
        .client_lo = std.mem.readInt(u64, bytes[16..24], .little),
        .sequence = std.mem.readInt(u64, bytes[24..32], .little),
        .expected = stampRead(bytes[32..56]),
        .name = .{ .ptr = bytes[request_header_size..].ptr, .len = name_len },
        .arg = .{ .ptr = if (arg_present == 1) bytes[request_header_size + name_len ..].ptr else null, .len = arg_len },
    };
}

pub fn writeSnapshot(buffer: []u8, value: workspace.Snapshot) ![]const u8 {
    if (buffer.len < snapshot_size or value.struct_size < @sizeOf(workspace.Snapshot) or
        value.api_version != workspace.version or value.reserved != 0) return error.InvalidWorkspaceWire;
    const bytes = buffer[0..snapshot_size];
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], workspace.version, .little);
    std.mem.writeInt(u32, bytes[4..8], value.flags, .little);
    stampWrite(bytes[8..32], value.stamp);
    std.mem.writeInt(u64, bytes[32..40], value.fingerprint, .little);
    std.mem.writeInt(u64, bytes[40..48], value.node_id_high_water, .little);
    std.mem.writeInt(u64, bytes[48..56], @intCast(value.text_len), .little);
    return bytes;
}

pub fn readSnapshot(bytes: []const u8) !workspace.Snapshot {
    if (bytes.len != snapshot_size or std.mem.readInt(u32, bytes[0..4], .little) != workspace.version or
        std.mem.readInt(u64, bytes[56..64], .little) != 0) return error.InvalidWorkspaceWire;
    const length = std.math.cast(usize, std.mem.readInt(u64, bytes[48..56], .little)) orelse return error.InvalidWorkspaceWire;
    return .{
        .stamp = stampRead(bytes[8..32]),
        .fingerprint = std.mem.readInt(u64, bytes[32..40], .little),
        .node_id_high_water = std.mem.readInt(u64, bytes[40..48], .little),
        .flags = std.mem.readInt(u32, bytes[4..8], .little),
        .text_len = length,
    };
}

pub fn writeOutcome(buffer: []u8, value: workspace.Outcome) ![]const u8 {
    if (buffer.len < outcome_size or value.struct_size < @sizeOf(workspace.Outcome) or value.api_version != workspace.version or
        std.enums.fromInt(workspace.Disposition, value.disposition) == null) return error.InvalidWorkspaceWire;
    const bytes = buffer[0..outcome_size];
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], workspace.version, .little);
    std.mem.writeInt(i32, bytes[4..8], value.status, .little);
    std.mem.writeInt(u32, bytes[8..12], value.disposition, .little);
    std.mem.writeInt(u64, bytes[16..24], value.sequence, .little);
    stampWrite(bytes[24..48], value.stamp);
    std.mem.writeInt(u64, bytes[48..56], value.created_id, .little);
    std.mem.writeInt(u64, bytes[56..64], value.task_id, .little);
    return bytes;
}

pub fn readOutcome(bytes: []const u8) !workspace.Outcome {
    if (bytes.len != outcome_size or std.mem.readInt(u32, bytes[0..4], .little) != workspace.version or
        std.mem.readInt(u32, bytes[12..16], .little) != 0) return error.InvalidWorkspaceWire;
    const disposition = std.mem.readInt(u32, bytes[8..12], .little);
    if (std.enums.fromInt(workspace.Disposition, disposition) == null) return error.InvalidWorkspaceWire;
    return .{
        .status = std.mem.readInt(i32, bytes[4..8], .little),
        .disposition = disposition,
        .sequence = std.mem.readInt(u64, bytes[16..24], .little),
        .stamp = stampRead(bytes[24..48]),
        .created_id = std.mem.readInt(u64, bytes[48..56], .little),
        .task_id = std.mem.readInt(u64, bytes[56..64], .little),
    };
}

test "workspace packets preserve request bytes and identity without pointers" {
    const name = "editor.invert.add";
    const arg = "c1";
    const value = workspace.Request{ .client_hi = 0xffff000011112222, .client_lo = 7, .sequence = 9, .expected = .{ .epoch_hi = 10, .epoch_lo = 20, .revision = 3 }, .name = .{ .ptr = name.ptr, .len = name.len }, .arg = .{ .ptr = arg.ptr, .len = arg.len } };
    const bytes = try encodeRequest(std.testing.allocator, &value);
    defer std.testing.allocator.free(bytes);
    const restored = try readRequest(bytes);
    try std.testing.expectEqual(value.client_hi, restored.client_hi);
    try std.testing.expectEqual(value.sequence, restored.sequence);
    try std.testing.expect(value.expected.eql(restored.expected));
    try std.testing.expectEqualStrings(name, restored.name.ptr.?[0..restored.name.len]);
    try std.testing.expectEqualStrings(arg, restored.arg.ptr.?[0..restored.arg.len]);
    bytes[4] = 2;
    try std.testing.expectError(error.InvalidWorkspaceWire, readRequest(bytes));
}

test "workspace snapshot request and metadata bind the copied document version" {
    const stamp = workspace.Stamp{ .epoch_hi = 11, .epoch_lo = 22, .revision = 33 };
    var request: [snapshot_request_size]u8 = undefined;
    try std.testing.expect((try readSnapshotRequest(try writeSnapshotRequest(&request, null))) == null);
    try std.testing.expect(stamp.eql((try readSnapshotRequest(try writeSnapshotRequest(&request, &stamp))).?));
    var packet: [snapshot_size]u8 = undefined;
    const metadata = workspace.Snapshot{ .stamp = stamp, .fingerprint = 44, .node_id_high_water = 55, .flags = 3, .text_len = 66 };
    const restored = try readSnapshot(try writeSnapshot(&packet, metadata));
    try std.testing.expect(metadata.stamp.eql(restored.stamp));
    try std.testing.expectEqual(metadata.fingerprint, restored.fingerprint);
    try std.testing.expectEqual(metadata.text_len, restored.text_len);
    packet[63] = 1;
    try std.testing.expectError(error.InvalidWorkspaceWire, readSnapshot(&packet));
}

test "workspace outcomes preserve rejection and replay dispositions" {
    var packet: [outcome_size]u8 = undefined;
    const value = workspace.Outcome{ .status = workspace.Status.stale_version, .disposition = @backingInt(workspace.Disposition.rejected), .sequence = 8, .stamp = .{ .epoch_hi = 1, .epoch_lo = 2, .revision = 3 }, .created_id = 7, .task_id = 9 };
    const restored = try readOutcome(try writeOutcome(&packet, value));
    try std.testing.expectEqual(value.status, restored.status);
    try std.testing.expectEqual(value.sequence, restored.sequence);
    try std.testing.expectEqual(value.created_id, restored.created_id);
    packet[8] = 9;
    try std.testing.expectError(error.InvalidWorkspaceWire, readOutcome(&packet));
}
