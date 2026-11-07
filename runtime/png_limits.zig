//! Shared bounds checked before stb allocates decoded Source pixels.
const std = @import("std");

pub const max_encoded_bytes = 16 * 1024 * 1024;
pub const max_decoded_bytes = 64 * 1024 * 1024;

pub fn decodedPngSize(bytes: []const u8) !usize {
    if (bytes.len < 33) return error.TruncatedImage;
    if (!std.mem.eql(u8, bytes[0..8], &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' })) return error.UnsupportedImageFormat;
    if (std.mem.readInt(u32, bytes[8..12], .big) != 13 or !std.mem.eql(u8, bytes[12..16], "IHDR")) return error.InvalidPngHeader;
    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    if (width == 0 or height == 0 or width > std.math.maxInt(c_int) or height > std.math.maxInt(c_int)) return error.InvalidImageSize;
    const stride = std.math.mul(usize, width, 4) catch return error.ExportDecodedBudgetExceeded;
    if (stride > std.math.maxInt(c_int)) return error.ExportDecodedBudgetExceeded;
    const size = std.math.mul(usize, stride, height) catch return error.ExportDecodedBudgetExceeded;
    if (size > max_decoded_bytes) return error.ExportDecodedBudgetExceeded;
    return size;
}

pub fn validateCandidate(allocator: std.mem.Allocator, bytes: []const u8) !void {
    if (bytes.len > max_encoded_bytes) return error.ExportEncodedBudgetExceeded;
    const expected = try decodedPngSize(bytes);
    var decoded = try @import("image.zig").decode(allocator, bytes);
    defer decoded.deinit(allocator);
    if (decoded.pixels.len != expected) return error.SourceDecodeSizeMismatch;
}
