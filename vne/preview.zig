//! Preview-frame wire contract shared by VM and Shell.
//!
//! This is the first half of the preview ABI: the VM owns evaluation and
//! returns a bounded BGRA frame tied to one document fingerprint/generation.
//! The Shell still needs a host RPC/transport adapter before it can stop
//! evaluating previews locally.

const std = @import("std");

pub const version: u32 = 2;

pub const Format = enum(u32) {
    bgra8 = 1,
};

pub const Info = extern struct {
    struct_size: u32,
    abi_version: u32,
    width: u32,
    height: u32,
    format: u32,
    reserved: u32 = 0,
    generation: u64,
    fingerprint: u64,
    epoch_hi: u64,
    epoch_lo: u64,
    revision: u64,
    bytes_len: usize,
};

pub fn expectedBytes(width: u32, height: u32) !usize {
    if (width == 0 or height == 0) return error.InvalidPreviewSize;
    const pixels = std.math.mul(u64, width, height) catch return error.InvalidPreviewSize;
    const bytes = std.math.mul(u64, pixels, 4) catch return error.InvalidPreviewSize;
    if (bytes > std.math.maxInt(usize)) return error.InvalidPreviewSize;
    return @intCast(bytes);
}

pub fn validateInfo(info: Info) !void {
    if (info.struct_size != @sizeOf(Info) or info.abi_version != version) return error.InvalidPreviewInfo;
    if (info.reserved != 0 or info.format != @intFromEnum(Format.bgra8)) return error.InvalidPreviewInfo;
    if (info.bytes_len != try expectedBytes(info.width, info.height)) return error.InvalidPreviewInfo;
    if (info.generation == 0 or info.fingerprint == 0) return error.InvalidPreviewInfo;
    if (info.epoch_hi == 0 and info.epoch_lo == 0) return error.InvalidPreviewInfo;
    if (info.revision == 0) return error.InvalidPreviewInfo;
}

pub fn validateRead(info: Info, buffer_len: usize) !void {
    try validateInfo(info);
    if (buffer_len < info.bytes_len) return error.PreviewBufferTooSmall;
}

test "preview info validates dimensions and exact byte length" {
    var info = Info{
        .struct_size = @sizeOf(Info),
        .abi_version = version,
        .width = 91,
        .height = 69,
        .format = @intFromEnum(Format.bgra8),
        .generation = 7,
        .fingerprint = 0x1234,
        .epoch_hi = 1,
        .epoch_lo = 2,
        .revision = 1,
        .bytes_len = 91 * 69 * 4,
    };
    try validateInfo(info);
    try validateRead(info, 91 * 69 * 4);
    try std.testing.expectError(error.PreviewBufferTooSmall, validateRead(info, 91 * 69 * 4 - 1));
    info.bytes_len = 4;
    try std.testing.expectError(error.InvalidPreviewInfo, validateInfo(info));
    info.bytes_len = 91 * 69 * 4;
    info.fingerprint = 0;
    try std.testing.expectError(error.InvalidPreviewInfo, validateInfo(info));
}

test "preview dimensions reject zero and overflow" {
    try std.testing.expectError(error.InvalidPreviewSize, expectedBytes(0, 1));
    try std.testing.expectError(error.InvalidPreviewSize, expectedBytes(0xFFFFFFFF, 0xFFFFFFFF));
}
