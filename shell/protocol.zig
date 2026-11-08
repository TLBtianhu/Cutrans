const std = @import("std");
pub const workspace_wire = @import("workspace_wire.zig");
pub const resource_wire = @import("resource_wire.zig");
pub const work_wire = @import("work_wire.zig");

pub const header_size = 32;
pub const max_payload = 16 * 1024 * 1024 + 1024 * 1024;
const request_magic = "CUTRSH2\x00";
const response_magic = "CUTRSR2\x00";

pub const Kind = enum(u32) {
    command_result = 1,
    document_fingerprint = 2,
    document_flags = 3,
    document_read = 4,
    pump = 5,
    input_push = 6,
    input_flush = 7,
    frame_report = 8,
    playback_report = 9,
    library_list = 10,
    library_label = 11,
    asset_list = 12,
    asset_source = 13,
    asset_preview = 14,
    asset_read = 15,
    asset_open_external = 16,
    document_open_external = 17,
    shell_handshake = 18,
    shell_commit = 19,
    input_begin = 20,
    input_end = 21,
    workspace_snapshot = 22,
    workspace_submit = 23,
    jobs_read = 24,
    source_read = 25,
    resource_snapshot = 26,
    resource_probe = 27,
    resource_submit = 28,
    work_snapshot = 29,
    work_submit = 30,
};

pub const source_read_version: u32 = 1;
pub const source_read_header_size: usize = 16;
pub const max_source_uri_size: usize = 1024 * 1024;
pub const SourceRead = struct { uri: []const u8, expected_sha256: []const u8 };

pub fn validSourceRead(uri: []const u8, expected_sha256: []const u8) bool {
    if (uri.len == 0 or uri.len > max_source_uri_size or std.mem.indexOfScalar(u8, uri, 0) != null) return false;
    if (expected_sha256.len != 0) {
        if (expected_sha256.len != 64) return false;
        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, expected_sha256) catch return false;
    }
    return true;
}

/// LE v1, URI length, hash length, reserved=0, URI bytes, optional 64 hex bytes.
pub fn encodeSourceRead(allocator: std.mem.Allocator, uri: []const u8, expected_sha256: []const u8) ![]u8 {
    if (!validSourceRead(uri, expected_sha256)) return error.InvalidSourceReadPayload;
    const bytes = try allocator.alloc(u8, source_read_header_size + uri.len + expected_sha256.len);
    @memset(bytes[0..source_read_header_size], 0);
    std.mem.writeInt(u32, bytes[0..4], source_read_version, .little);
    std.mem.writeInt(u32, bytes[4..8], @intCast(uri.len), .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(expected_sha256.len), .little);
    @memcpy(bytes[source_read_header_size..][0..uri.len], uri);
    @memcpy(bytes[source_read_header_size + uri.len ..], expected_sha256);
    return bytes;
}

pub fn parseSourceRead(bytes: []const u8) !SourceRead {
    if (bytes.len < source_read_header_size or std.mem.readInt(u32, bytes[0..4], .little) != source_read_version or
        std.mem.readInt(u32, bytes[12..16], .little) != 0) return error.InvalidSourceReadPayload;
    const uri_len: usize = std.mem.readInt(u32, bytes[4..8], .little);
    const hash_len: usize = std.mem.readInt(u32, bytes[8..12], .little);
    if (uri_len == 0 or uri_len > max_source_uri_size or (hash_len != 0 and hash_len != 64) or
        bytes.len != source_read_header_size + uri_len + hash_len) return error.InvalidSourceReadPayload;
    const value = SourceRead{ .uri = bytes[source_read_header_size..][0..uri_len], .expected_sha256 = bytes[source_read_header_size + uri_len ..] };
    if (!validSourceRead(value.uri, value.expected_sha256)) return error.InvalidSourceReadPayload;
    return value;
}

pub const Request = struct {
    kind: Kind,
    id: u64 = 0,
    payload_len: u32 = 0,
};

pub const Response = struct {
    kind: Kind,
    status: i32,
    value: u64 = 0,
    payload_len: u32 = 0,
};

pub fn isRequest(bytes: []const u8) bool {
    return bytes.len == header_size and std.mem.eql(u8, bytes[0..8], request_magic);
}

pub fn parseRequest(bytes: []const u8) !Request {
    if (!isRequest(bytes)) return error.InvalidShellRequest;
    if (std.mem.readInt(u32, bytes[12..16], .little) != 0 or std.mem.readInt(u32, bytes[28..32], .little) != 0) return error.InvalidShellRequest;
    const kind_value = std.enums.fromInt(Kind, std.mem.readInt(u32, bytes[8..12], .little)) orelse return error.InvalidShellRequest;
    const payload_len = std.mem.readInt(u32, bytes[24..28], .little);
    if (payload_len > max_payload) return error.InvalidShellRequest;
    return .{ .kind = kind_value, .id = std.mem.readInt(u64, bytes[16..24], .little), .payload_len = payload_len };
}

pub fn writeRequest(buffer: []u8, request: Request) ![]const u8 {
    if (buffer.len < header_size or request.payload_len > max_payload) return error.InvalidShellRequest;
    @memset(buffer[0..header_size], 0);
    @memcpy(buffer[0..8], request_magic);
    std.mem.writeInt(u32, buffer[8..12], @backingInt(request.kind), .little);
    std.mem.writeInt(u64, buffer[16..24], request.id, .little);
    std.mem.writeInt(u32, buffer[24..28], request.payload_len, .little);
    return buffer[0..header_size];
}

pub fn writeResponse(buffer: []u8, response: Response) ![]const u8 {
    if (buffer.len < header_size or response.payload_len > max_payload) return error.InvalidShellResponse;
    @memset(buffer[0..header_size], 0);
    @memcpy(buffer[0..8], response_magic);
    std.mem.writeInt(u32, buffer[8..12], @backingInt(response.kind), .little);
    std.mem.writeInt(i32, buffer[12..16], response.status, .little);
    std.mem.writeInt(u64, buffer[16..24], response.value, .little);
    std.mem.writeInt(u32, buffer[24..28], response.payload_len, .little);
    return buffer[0..header_size];
}

pub fn parseResponse(bytes: []const u8, expected_kind: Kind) !Response {
    if (bytes.len != header_size or !std.mem.eql(u8, bytes[0..8], response_magic)) return error.InvalidShellResponse;
    if (std.mem.readInt(u32, bytes[28..32], .little) != 0) return error.InvalidShellResponse;
    const kind = std.enums.fromInt(Kind, std.mem.readInt(u32, bytes[8..12], .little)) orelse return error.InvalidShellResponse;
    if (kind != expected_kind) return error.InvalidShellResponse;
    const payload_len = std.mem.readInt(u32, bytes[24..28], .little);
    if (payload_len > max_payload) return error.InvalidShellResponse;
    return .{
        .kind = kind,
        .status = std.mem.readInt(i32, bytes[12..16], .little),
        .value = std.mem.readInt(u64, bytes[16..24], .little),
        .payload_len = payload_len,
    };
}

test "shell RPC headers preserve operation identity and reject invalid payloads" {
    var buffer: [header_size]u8 = undefined;
    const request = Request{ .kind = .asset_read, .id = 42, .payload_len = 128 };
    const encoded_request = try writeRequest(&buffer, request);
    const decoded_request = try parseRequest(encoded_request);
    try std.testing.expectEqual(request.kind, decoded_request.kind);
    try std.testing.expectEqual(request.id, decoded_request.id);
    try std.testing.expectEqual(request.payload_len, decoded_request.payload_len);
    const response = Response{ .kind = .asset_read, .status = 0, .value = 7, .payload_len = 128 };
    const encoded_response = try writeResponse(&buffer, response);
    const decoded_response = try parseResponse(encoded_response, .asset_read);
    try std.testing.expectEqual(response.status, decoded_response.status);
    try std.testing.expectEqual(response.value, decoded_response.value);
    try std.testing.expectEqual(response.payload_len, decoded_response.payload_len);
    try std.testing.expectError(error.InvalidShellResponse, parseResponse(encoded_response, .asset_list));
    buffer[8] = 255;
    try std.testing.expectError(error.InvalidShellRequest, parseRequest(&buffer));
}

test "source reading frames preserve exact version and reject ambiguous payloads" {
    const uri = "library://9";
    const expected = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const bytes = try encodeSourceRead(std.testing.allocator, uri, expected);
    defer std.testing.allocator.free(bytes);
    const value = try parseSourceRead(bytes);
    try std.testing.expectEqualStrings(uri, value.uri);
    try std.testing.expectEqualStrings(expected, value.expected_sha256);
    bytes[12] = 1;
    try std.testing.expectError(error.InvalidSourceReadPayload, parseSourceRead(bytes));
    bytes[12] = 0;
    bytes[bytes.len - 1] = 'g';
    try std.testing.expectError(error.InvalidSourceReadPayload, parseSourceRead(bytes));
    const current = try encodeSourceRead(std.testing.allocator, uri, "");
    defer std.testing.allocator.free(current);
    try std.testing.expectEqual(@as(usize, 0), (try parseSourceRead(current)).expected_sha256.len);
    try std.testing.expectError(error.InvalidSourceReadPayload, parseSourceRead(current[0 .. current.len - 1]));
    try std.testing.expectError(error.InvalidSourceReadPayload, encodeSourceRead(std.testing.allocator, "", ""));
    try std.testing.expectError(error.InvalidSourceReadPayload, encodeSourceRead(std.testing.allocator, "library://9\x00ignored", ""));
    try std.testing.expectError(error.InvalidSourceReadPayload, encodeSourceRead(std.testing.allocator, uri, expected[0..63]));
}
