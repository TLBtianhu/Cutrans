//! Versioned document requests. ABI8 transports this independently versioned API.
const std = @import("std");
const commands = @import("commands.zig");

pub const version: u32 = 1;
pub const receipt_capacity = 64;
pub const default_client_limit = 4096;

pub const Status = struct {
    pub const stale_version: i32 = 16;
    pub const wrong_epoch: i32 = 17;
    pub const request_conflict: i32 = 18;
    pub const receipt_expired: i32 = 19;
    pub const bad_sequence: i32 = 20;
    pub const client_limit: i32 = 21;
    pub const unsupported_command: i32 = 22;
};

pub const Stamp = extern struct {
    epoch_hi: u64 = 0,
    epoch_lo: u64 = 0,
    revision: u64 = 0,

    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.epoch_hi == b.epoch_hi and a.epoch_lo == b.epoch_lo and a.revision == b.revision;
    }
};

pub const Bytes = extern struct { ptr: ?[*]const u8 = null, len: usize = 0 };

pub const Request = extern struct {
    struct_size: u32 = @sizeOf(Request),
    api_version: u32 = version,
    client_hi: u64,
    client_lo: u64,
    sequence: u64,
    expected: Stamp,
    name: Bytes,
    arg: Bytes = .{},
};

pub const Disposition = enum(u32) { executed = 1, replayed = 2, rejected = 3 };

pub const Outcome = extern struct {
    struct_size: u32 = @sizeOf(Outcome),
    api_version: u32 = version,
    status: i32,
    disposition: u32,
    sequence: u64,
    stamp: Stamp,
    created_id: u64 = 0,
    task_id: u64 = 0,
};

pub const Snapshot = extern struct {
    struct_size: u32 = @sizeOf(Snapshot),
    api_version: u32 = version,
    stamp: Stamp,
    fingerprint: u64,
    node_id_high_water: u64,
    flags: u32,
    reserved: u32 = 0,
    text_len: usize,
};

pub const Api = extern struct {
    struct_size: u32 = @sizeOf(Api),
    api_version: u32 = version,
    context: ?*anyopaque,
    /// Query with null buffer/expected, then read using the returned stamp.
    /// A changed stamp refuses the read without writing document bytes.
    snapshot: *const fn (?*anyopaque, ?*const Stamp, ?*Snapshot, ?[*]u8, usize, ?*usize) callconv(.c) i32,
    /// Zero means Outcome is known, even when Outcome.status refuses the edit.
    /// Nonzero leaves execution unknown: retry the IDENTICAL request. Names
    /// must be 1..64 bytes, arguments at most 1MiB. Callers validate before send.
    /// Receipts survive only within this Runtime incarnation. Old epochs fail
    /// closed; they cannot establish whether an old Runtime committed a request.
    submit: *const fn (?*anyopaque, ?*const Request, ?*Outcome) callconv(.c) i32,
};

/// Only document edits and snapshot-bound export admission are retry managed.
/// Library, filesystem saving, and external grants keep their explicit legacy contracts.
pub fn manages(name: []const u8) bool {
    return commands.isManaged(name);
}

pub fn createsNode(name: []const u8) bool {
    return commands.isNodeCreating(name);
}

test "document stamps include the Runtime incarnation and mutation sequence" {
    const stamp = Stamp{ .epoch_hi = 1, .epoch_lo = 2, .revision = 1 };
    try std.testing.expect(stamp.eql(stamp));
    try std.testing.expect(!stamp.eql(.{ .epoch_hi = 1, .epoch_lo = 3, .revision = 1 }));
    try std.testing.expect(manages("editor.export.png"));
    try std.testing.expect(manages("doc.save"));
    try std.testing.expect(!manages("library.rename"));
}
