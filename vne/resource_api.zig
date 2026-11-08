//! Versioned resource-catalog requests, independent of document edit stamps.
const std = @import("std");

pub const version: u32 = 3;
pub const max_path_size: usize = 64 * 1024;
pub const max_work_body_size: usize = 16 * 1024 * 1024;
pub const max_work_label_size: usize = 128;
pub const receipt_capacity: usize = 64;
pub const default_client_limit: usize = 4096;

pub const Status = struct {
    pub const stale_version: i32 = 64;
    pub const wrong_epoch: i32 = 65;
    pub const request_conflict: i32 = 66;
    pub const receipt_expired: i32 = 67;
    pub const bad_sequence: i32 = 68;
    pub const client_limit: i32 = 69;
    pub const candidate_changed: i32 = 70;
    pub const wrong_kind: i32 = 71;
    pub const content_mismatch: i32 = 72;
    pub const draft_conflict: i32 = 73;
    pub const receipt_limit: i32 = 74;
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
pub const Mode = enum(u32) { relocate = 1, adopt = 2, register_file = 3 };
pub const Disposition = enum(u32) { executed = 1, replayed = 2, rejected = 3 };

/// A stateless observation, not an authorization capability or a held file
/// lease. Submit reopens the exact path and checks the observed identity/hash.
pub const Proof = extern struct {
    struct_size: u32 = @sizeOf(Proof),
    api_version: u32 = version,
    stamp: Stamp,
    target_id: u64,
    mode: u32,
    reserved: u32 = 0,
    head_hash: [32]u8,
    content_hash: [32]u8,
    path_hash: [32]u8,
    byte_length: u64,
    volume_serial: u64,
    file_index: u64,
};

pub const ProbeRequest = extern struct {
    struct_size: u32 = @sizeOf(ProbeRequest),
    api_version: u32 = version,
    expected: Stamp,
    target_id: u64,
    mode: u32,
    reserved: u32 = 0,
    path: Bytes,
};

pub const Request = extern struct {
    struct_size: u32 = @sizeOf(Request),
    api_version: u32 = version,
    client_hi: u64,
    client_lo: u64,
    sequence: u64,
    proof: Proof,
    path: Bytes,
};

pub const Outcome = extern struct {
    struct_size: u32 = @sizeOf(Outcome),
    api_version: u32 = version,
    status: i32,
    disposition: u32,
    sequence: u64,
    stamp: Stamp,
    resource_id: u64 = 0,
};

pub const Snapshot = extern struct {
    struct_size: u32 = @sizeOf(Snapshot),
    api_version: u32 = version,
    stamp: Stamp,
    text_len: usize,
};

pub const WorkMode = enum(u32) { create = 1, save_draft = 2, commit = 3, discard = 4 };
pub const WorkBody = enum(u32) { published = 1, draft = 2 };

pub const WorkSnapshot = extern struct {
    struct_size: u32 = @sizeOf(WorkSnapshot),
    api_version: u32 = version,
    stamp: Stamp,
    resource_id: u64,
    work_revision: u64,
    base_revision: u64,
    draft_revision: u64,
    body_origin: u32,
    reserved: u32 = 0,
    content_hash: [32]u8,
    body_hash: [32]u8,
    body_len: usize,
};

pub const WorkRequest = extern struct {
    struct_size: u32 = @sizeOf(WorkRequest),
    api_version: u32 = version,
    client_hi: u64,
    client_lo: u64,
    sequence: u64,
    resource_id: u64 = 0,
    base_revision: u64 = 0,
    expected_draft_revision: u64 = 0,
    mode: u32,
    reserved: u32 = 0,
    label: Bytes = .{},
    body: Bytes = .{},
};

pub const WorkOutcome = extern struct {
    struct_size: u32 = @sizeOf(WorkOutcome),
    api_version: u32 = version,
    status: i32,
    disposition: u32,
    sequence: u64,
    stamp: Stamp,
    resource_id: u64,
    work_revision: u64,
    draft_revision: u64,
    content_hash: [32]u8,
};

pub const Api = extern struct {
    struct_size: u32 = @sizeOf(Api),
    api_version: u32 = version,
    context: ?*anyopaque,
    /// Query null expected/buffer, then read with that exact resource stamp.
    /// Revision zero is valid for an empty catalog. No partial bytes on failure.
    snapshot: *const fn (?*anyopaque, ?*const Stamp, ?*Snapshot, ?[*]u8, usize, ?*usize) callconv(.c) i32,
    /// A single fixed-size proof read; probing never mutates the catalog or
    /// acquires a remote Station lease. Paths are at most 64KiB and NUL-free.
    probe: *const fn (?*anyopaque, ?*const ProbeRequest, ?*Proof) callconv(.c) i32,
    /// Zero means Outcome is known. Nonzero leaves execution unknown: retain
    /// and retry the identical request, including the original proof/path.
    /// Receipts are incarnation-local; never automatically retry across epochs.
    submit: *const fn (?*anyopaque, ?*const Request, ?*Outcome) callconv(.c) i32,
    /// The second call passes the first snapshot back as expected. A draft is
    /// returned when present; otherwise the current published work body is read.
    work_snapshot: *const fn (?*anyopaque, u64, ?*const WorkSnapshot, ?*WorkSnapshot, ?[*]u8, usize, ?*usize) callconv(.c) i32 = undefined,
    /// Successful work receipts persist with the Catalog commit. Replaying the
    /// identical request consults that receipt before current revision checks.
    work_submit: *const fn (?*anyopaque, ?*const WorkRequest, ?*WorkOutcome) callconv(.c) i32 = undefined,

    pub fn isCurrent(self: *const Api) bool {
        return self.struct_size == @sizeOf(Api) and self.api_version == version and self.context != null;
    }
};

pub fn validPath(path: []const u8) bool {
    return path.len != 0 and path.len <= max_path_size and std.mem.indexOfScalar(u8, path, 0) == null;
}

pub fn validProof(value: *const Proof) bool {
    if (value.struct_size != @sizeOf(Proof) or value.api_version != version or value.reserved != 0) return false;
    const mode = std.enums.fromInt(Mode, value.mode) orelse return false;
    return if (mode == .register_file)
        value.target_id == 0 and std.mem.allEqual(u8, &value.head_hash, 0)
    else
        value.target_id != 0;
}

pub fn validWorkRequest(value: *const WorkRequest) bool {
    if (value.struct_size != @sizeOf(WorkRequest) or value.api_version != version or value.reserved != 0) return false;
    if ((value.client_hi == 0 and value.client_lo == 0) or value.sequence == 0) return false;
    if (value.label.len > max_work_label_size or value.body.len > max_work_body_size) return false;
    if (value.label.len != 0 and value.label.ptr == null) return false;
    if (value.body.len != 0 and value.body.ptr == null) return false;
    const mode = std.enums.fromInt(WorkMode, value.mode) orelse return false;
    return switch (mode) {
        .create => value.resource_id == 0 and value.base_revision == 0 and value.expected_draft_revision == 0 and value.label.len != 0,
        .save_draft => value.resource_id != 0 and value.base_revision != 0 and value.label.len == 0,
        .commit, .discard => value.resource_id != 0 and value.base_revision == 0 and value.expected_draft_revision != 0 and value.body.len == 0 and value.label.len == 0,
    };
}

test "resource stamps allow empty catalogs and use an independent status domain" {
    const stamp = Stamp{ .epoch_hi = 1, .epoch_lo = 2 };
    try std.testing.expect(stamp.eql(stamp));
    try std.testing.expect(!stamp.eql(.{ .epoch_hi = 1, .epoch_lo = 3 }));
    try std.testing.expect(Status.stale_version >= 64);
    try std.testing.expect(!validPath(""));
    try std.testing.expect(!validPath("C:/file\x00ignored"));
}

test "registration has no existing target and old proofs are incompatible" {
    var proof: Proof = .{ .stamp = .{}, .target_id = 0, .mode = @backingInt(Mode.register_file), .head_hash = @splat(0), .content_hash = @splat(1), .path_hash = @splat(2), .byte_length = 0, .volume_serial = 1, .file_index = 2 };
    try std.testing.expect(validProof(&proof));
    proof.target_id = 1;
    try std.testing.expect(!validProof(&proof));
    proof.target_id = 0;
    proof.head_hash[0] = 1;
    try std.testing.expect(!validProof(&proof));
    proof.head_hash[0] = 0;
    proof.api_version = 2;
    try std.testing.expect(!validProof(&proof));
}

test "work requests separate new drafts from commit and discard" {
    var request = WorkRequest{ .client_hi = 1, .client_lo = 2, .sequence = 1, .mode = @backingInt(WorkMode.create), .label = .{ .ptr = "note.txt".ptr, .len = 8 } };
    try std.testing.expect(validWorkRequest(&request));
    request.mode = @backingInt(WorkMode.save_draft);
    try std.testing.expect(!validWorkRequest(&request));
    request.resource_id = 3;
    request.base_revision = 1;
    try std.testing.expect(validWorkRequest(&request));
    request.mode = @backingInt(WorkMode.commit);
    try std.testing.expect(!validWorkRequest(&request));
    request.label = .{};
    request.expected_draft_revision = 4;
    try std.testing.expect(validWorkRequest(&request));
    request.api_version = 2;
    try std.testing.expect(!validWorkRequest(&request));
}
