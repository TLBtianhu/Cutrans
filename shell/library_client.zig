//! Shell-owned resource projections and retry-managed intents. This module has
//! no GUI or Runtime Context dependency and never rebases an unknown request.
const std = @import("std");
const abi = @import("vne").abi;
const resource = @import("vne").resource_api;
const library = @import("vne").library;

pub const max_snapshot_bytes = 1024 * 1024;
pub const ClientId = [2]u64;

pub const NonceSource = struct {
    context: ?*anyopaque,
    next: *const fn (?*anyopaque) anyerror!ClientId,

    /// The caller keeps this Io value and its backing implementation alive.
    pub fn secure(io: *const std.Io) NonceSource {
        return .{ .context = @constCast(io), .next = secureNext };
    }

    fn secureNext(pointer: ?*anyopaque) !ClientId {
        const io: *const std.Io = @ptrCast(@alignCast(pointer orelse return error.ClientEntropyUnavailable));
        var value: ClientId = undefined;
        try io.randomSecure(std.mem.asBytes(&value));
        if (value[0] == 0 and value[1] == 0) return error.ClientEntropyUnavailable;
        return value;
    }
};

pub const Projection = struct {
    stamp: ?resource.Stamp = null,
    next_id: u64 = 1,
    view: library.View = .{},

    pub fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        self.view.deinit(allocator);
        self.* = .{};
    }
};

pub const Candidate = struct {
    proof: resource.Proof,
    path: []u8,

    fn deinit(self: Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

const Pending = struct {
    candidate: Candidate,
    client_id: ClientId,
    sequence: u64,
};

pub const Settlement = struct {
    outcome: resource.Outcome,
    client_id: ClientId,
    /// Content from the exact settled candidate, independent of a later view.
    content_hash: [32]u8,
    /// A new Runtime or an expired receipt cannot prove the old result.
    previous_result_uncertain: bool,
};

pub const Submission = union(enum) { unknown, known: Settlement };

pub const Client = struct {
    allocator: std.mem.Allocator,
    authority: resource.Api,
    nonces: NonceSource,
    projection: Projection = .{},
    projection_error: ?anyerror = null,
    last_probe_status: ?i32 = null,
    last_transport_status: ?i32 = null,
    identity: ?ClientId = null,
    next_sequence: u64 = 1,
    prepared: ?Candidate = null,
    pending_request: ?Pending = null,
    last_settlement: ?Settlement = null,

    /// Validate the ABI prefix before reading the new resource getter.
    pub fn init(allocator: std.mem.Allocator, shell_api: *const abi.ShellApi, nonces: NonceSource) !Client {
        if (!shell_api.isCurrent()) return error.InvalidShellApi;
        if (shell_api.context == null) return error.MissingRuntimeHandle;
        var authority: resource.Api = undefined;
        if (shell_api.resource_api(shell_api.context, &authority) != abi.Status.ok) return error.ResourceApiUnavailable;
        return initApi(allocator, &authority, nonces);
    }

    fn initApi(allocator: std.mem.Allocator, authority: *const resource.Api, nonces: NonceSource) !Client {
        if (!authority.isCurrent()) return error.InvalidResourceApi;
        return .{ .allocator = allocator, .authority = authority.*, .nonces = nonces };
    }

    pub fn deinit(self: *Client) void {
        if (self.prepared) |value| value.deinit(self.allocator);
        if (self.pending_request) |value| value.candidate.deinit(self.allocator);
        self.projection.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn hasPending(self: *const Client) bool {
        return self.pending_request != null;
    }

    pub fn candidate(self: *const Client) ?*const Candidate {
        return if (self.prepared) |*value| value else null;
    }

    pub fn lastSettlement(self: *const Client) ?Settlement {
        return self.last_settlement;
    }

    /// Reads are allowed while a mutation result is unknown. Failure keeps the
    /// entire previously published projection and the exact pending request.
    pub fn refresh(self: *Client) !void {
        self.refreshProjection() catch |err| {
            self.projection_error = err;
            return err;
        };
        self.projection_error = null;
    }

    fn refreshProjection(self: *Client) !void {
        var metadata: resource.Snapshot = undefined;
        var required: usize = 0;
        const query = self.authority.snapshot(self.authority.context, null, &metadata, null, 0, &required);
        if (query != abi.Status.buffer_too_small) return error.ResourceSnapshotQueryFailed;
        if (!validSnapshot(metadata) or required != metadata.text_len or required == 0 or required > max_snapshot_bytes)
            return error.InvalidResourceSnapshot;
        const bytes = try self.allocator.alloc(u8, required);
        defer self.allocator.free(bytes);
        var actual: resource.Snapshot = undefined;
        var copied: usize = 0;
        const status = self.authority.snapshot(self.authority.context, &metadata.stamp, &actual, bytes.ptr, bytes.len, &copied);
        if (status == resource.Status.stale_version or status == resource.Status.wrong_epoch) return error.ResourceSnapshotChanged;
        if (status != abi.Status.ok) return error.ResourceSnapshotReadFailed;
        if (!validSnapshot(actual) or !actual.stamp.eql(metadata.stamp) or actual.text_len != metadata.text_len or copied != bytes.len)
            return error.InvalidResourceSnapshot;
        var next = try parseProjection(self.allocator, bytes, actual.stamp);
        errdefer next.deinit(self.allocator);
        self.projection.deinit(self.allocator);
        self.projection = next;
    }

    /// Probe is a new explicit intent. Keep an earlier candidate on probe
    /// failure; a successful proof owns the original path, not a later view.
    pub fn probe(self: *Client, target_id: u64, mode: resource.Mode, path: []const u8) !void {
        if (self.pending_request != null) return error.ResourceResultUnknown;
        const registering = mode == .register_file;
        if (!validCandidatePath(path) or (registering and target_id != 0) or (!registering and target_id == 0)) return error.InvalidCandidate;
        const expected = self.projection.stamp orelse return error.ResourceSnapshotRequired;
        const item = if (registering) null else self.projection.view.findResource(target_id) orelse return error.ResourceNotFound;
        if (item) |value| if (value.kind != .reference) return error.NotExternalReference;
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        const request = resource.ProbeRequest{ .expected = expected, .target_id = target_id, .mode = @backingInt(mode), .path = .{ .ptr = owned.ptr, .len = owned.len } };
        var proof: resource.Proof = undefined;
        const status = self.authority.probe(self.authority.context, &request, &proof);
        self.last_probe_status = status;
        if (status != abi.Status.ok) return error.ResourceProbeRefused;
        const head: [32]u8 = if (item) |value| value.content_hash else @splat(0);
        if (!resource.validProof(&proof) or !proof.stamp.eql(expected) or proof.target_id != target_id or proof.mode != @backingInt(mode) or !std.mem.eql(u8, &proof.head_hash, &head)) return error.InvalidResourceProof;
        if (self.prepared) |previous| previous.deinit(self.allocator);
        self.prepared = .{ .proof = proof, .path = owned };
    }

    /// Submit never implicitly refreshes. A committed result remains known if
    /// the caller's later refresh fails. A candidate is consumed once started.
    pub fn submit(self: *Client) !Submission {
        if (self.pending_request != null) return error.ResourceResultUnknown;
        const value = self.prepared orelse return error.ResourceCandidateRequired;
        if (!validCandidatePath(value.path) or !resource.validProof(&value.proof) or !validStamp(value.proof.stamp))
            return error.InvalidCandidate;
        if (self.identity == null) {
            const identity = try self.nonces.next(self.nonces.context);
            if (identity[0] == 0 and identity[1] == 0) return error.ClientEntropyUnavailable;
            self.identity = identity;
            self.next_sequence = 1;
        }
        self.pending_request = .{ .candidate = value, .client_id = self.identity.?, .sequence = self.next_sequence };
        self.prepared = null;
        return self.submitPending();
    }

    pub fn retry(self: *Client) !Submission {
        if (self.pending_request == null) return error.NoPendingResourceRequest;
        return self.submitPending();
    }

    fn submitPending(self: *Client) Submission {
        const pending = self.pending_request.?;
        const request = resource.Request{ .client_hi = pending.client_id[0], .client_lo = pending.client_id[1], .sequence = pending.sequence, .proof = pending.candidate.proof, .path = .{ .ptr = pending.candidate.path.ptr, .len = pending.candidate.path.len } };
        var outcome: resource.Outcome = undefined;
        const transport = self.authority.submit(self.authority.context, &request, &outcome);
        self.last_transport_status = transport;
        if (transport != abi.Status.ok or !validOutcome(outcome, pending)) return .unknown;
        const status = outcome.status;
        const settlement = Settlement{ .outcome = outcome, .client_id = pending.client_id, .content_hash = pending.candidate.proof.content_hash, .previous_result_uncertain = status == resource.Status.wrong_epoch or status == resource.Status.receipt_expired };
        pending.candidate.deinit(self.allocator);
        self.pending_request = null;
        self.last_settlement = settlement;
        if (status == resource.Status.wrong_epoch or status == resource.Status.receipt_expired or status == resource.Status.request_conflict or status == resource.Status.bad_sequence) {
            // Only a later explicit submit obtains a new nonce. Never translate
            // this old payload into a fresh request for the current Runtime.
            self.identity = null;
            self.next_sequence = 1;
        } else if (!(outcome.disposition == @backingInt(resource.Disposition.rejected) and (status == abi.Status.invalid_arguments or status == resource.Status.client_limit))) {
            if (self.next_sequence == std.math.maxInt(u64)) {
                self.identity = null;
                self.next_sequence = 1;
            } else self.next_sequence += 1;
        }
        return .{ .known = settlement };
    }
};

fn validCandidatePath(path: []const u8) bool {
    return resource.validPath(path) and std.fs.path.isAbsolute(path);
}

fn validStamp(stamp: resource.Stamp) bool {
    return stamp.epoch_hi != 0 or stamp.epoch_lo != 0;
}

fn validSnapshot(value: resource.Snapshot) bool {
    return value.struct_size == @sizeOf(resource.Snapshot) and value.api_version == resource.version and validStamp(value.stamp);
}

fn validOutcome(value: resource.Outcome, pending: Pending) bool {
    if (value.struct_size != @sizeOf(resource.Outcome) or value.api_version != resource.version or
        value.sequence != pending.sequence or !validStamp(value.stamp) or std.enums.fromInt(resource.Disposition, value.disposition) == null)
        return false;
    const expected = pending.candidate.proof.stamp;
    if (value.status != resource.Status.wrong_epoch and
        (value.stamp.epoch_hi != expected.epoch_hi or value.stamp.epoch_lo != expected.epoch_lo or value.stamp.revision < expected.revision))
        return false;
    if (pending.candidate.proof.mode == @backingInt(resource.Mode.register_file))
        return if (value.status == abi.Status.ok) value.resource_id != 0 else value.resource_id == 0;
    return (value.resource_id == 0 or value.resource_id == pending.candidate.proof.target_id) and
        (value.status != abi.Status.ok or value.resource_id == pending.candidate.proof.target_id);
}

const FolderEntry = struct { id: u64, parent_id: u64, label: []const u8 };
const ResourceEntry = struct { id: u64, parent_id: u64, label: []const u8, kind: []const u8, provenance: []const u8, source: []const u8, sha256: []const u8 };
const Manifest = struct { format: []const u8, next_id: u64, folders: []FolderEntry, resources: []ResourceEntry };

fn validEntry(id: u64, next_id: u64, label: []const u8) bool {
    if (id == 0 or (next_id != 0 and id >= next_id) or label.len == 0 or label.len > 128) return false;
    return std.mem.indexOf(u8, label, "..") == null and std.mem.indexOfAny(u8, label, "/\\:\x00") == null;
}

fn parseProjection(allocator: std.mem.Allocator, bytes: []const u8, stamp: resource.Stamp) !Projection {
    const parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{ .ignore_unknown_fields = false, .allocate = .alloc_always });
    defer parsed.deinit();
    const manifest = parsed.value;
    if (!std.mem.eql(u8, manifest.format, "cutrans-resource-snapshot/1") or manifest.folders.len > library.max_items or manifest.resources.len > library.max_items - manifest.folders.len) return error.InvalidResourceSnapshot;
    var result: Projection = .{ .stamp = stamp, .next_id = manifest.next_id };
    errdefer result.deinit(allocator);
    for (manifest.folders) |entry| {
        if (!validEntry(entry.id, manifest.next_id, entry.label)) return error.InvalidResourceSnapshot;
        const label = try allocator.dupe(u8, entry.label);
        result.view.items[result.view.count] = .{ .id = entry.id, .parent_id = entry.parent_id, .label = label, .node_kind = .folder };
        result.view.count += 1;
    }
    for (manifest.resources) |entry| {
        if (!validEntry(entry.id, manifest.next_id, entry.label) or entry.sha256.len != 64) return error.InvalidResourceSnapshot;
        const kind = std.meta.stringToEnum(library.Kind, entry.kind) orelse return error.InvalidResourceSnapshot;
        const provenance = std.meta.stringToEnum(library.Provenance, entry.provenance) orelse return error.InvalidResourceSnapshot;
        if (entry.source.len != 0) {
            const uri = @import("vne").uri.parse(entry.source) catch return error.InvalidResourceSnapshot;
            if (uri.root != .external) return error.InvalidResourceSnapshot;
        } else if (kind == .reference) return error.InvalidResourceSnapshot;
        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, entry.sha256) catch return error.InvalidResourceSnapshot;
        for (entry.sha256) |byte| if (byte >= 'A' and byte <= 'F') return error.InvalidResourceSnapshot;
        const label = try allocator.dupe(u8, entry.label);
        result.view.items[result.view.count] = .{ .id = entry.id, .parent_id = entry.parent_id, .label = label, .node_kind = .resource, .kind = kind, .provenance = provenance, .content_hash = digest };
        result.view.count += 1;
    }
    try result.view.validate();
    result.view.revision = stamp.revision;
    return result;
}

const test_manifest = "{\"format\":\"cutrans-resource-snapshot/1\",\"next_id\":2,\"folders\":[],\"resources\":[{\"id\":1,\"parent_id\":0,\"label\":\"original.png\",\"kind\":\"reference\",\"provenance\":\"external\",\"source\":\"external://1\",\"sha256\":\"1111111111111111111111111111111111111111111111111111111111111111\"}]}";
const test_path = if (@import("builtin").os.tag == .windows) "C:/candidate with spaces.png" else "/candidate with spaces.png";

const Nonces = struct {
    calls: u64 = 0,

    fn next(pointer: ?*anyopaque) !ClientId {
        const self: *Nonces = @ptrCast(@alignCast(pointer.?));
        self.calls += 1;
        return .{ 101, self.calls };
    }

    fn source(self: *Nonces) NonceSource {
        return .{ .context = self, .next = next };
    }
};

const Fake = struct {
    stamp: resource.Stamp = .{ .epoch_hi = 7, .epoch_lo = 8, .revision = 1 },
    text: []const u8 = test_manifest,
    fail_query: bool = false,
    change_after_query: bool = false,
    short_read: bool = false,
    lose_response: bool = false,
    malformed_outcome: bool = false,
    force_status: ?i32 = null,
    execute_status: i32 = abi.Status.ok,
    reply_epoch: ?ClientId = null,
    reply_revision: ?u64 = null,
    probes: usize = 0,
    submits: usize = 0,
    mutations: usize = 0,
    received: ?resource.Request = null,
    received_path: [128]u8 = undefined,
    receipt: ?resource.Outcome = null,
    receipt_proof: resource.Proof = undefined,
    receipt_client: ClientId = undefined,
    receipt_path: [128]u8 = undefined,
    receipt_path_len: usize = 0,

    fn state(pointer: ?*anyopaque) *Fake {
        return @ptrCast(@alignCast(pointer.?));
    }

    fn snapshot(pointer: ?*anyopaque, expected: ?*const resource.Stamp, out: ?*resource.Snapshot, buffer: ?[*]u8, capacity: usize, length: ?*usize) callconv(.c) i32 {
        const self = state(pointer);
        length.?.* = 0;
        if (self.fail_query) return abi.Status.failed;
        out.?.* = .{ .stamp = self.stamp, .text_len = self.text.len };
        if (expected) |value| if (!value.eql(self.stamp)) return resource.Status.stale_version;
        length.?.* = self.text.len;
        if (buffer == null) {
            if (self.change_after_query) {
                self.change_after_query = false;
                self.stamp.revision += 1;
            }
            return abi.Status.buffer_too_small;
        }
        if (self.short_read or capacity < self.text.len) return abi.Status.buffer_too_small;
        @memcpy(buffer.?[0..self.text.len], self.text);
        return abi.Status.ok;
    }

    fn probe(pointer: ?*anyopaque, request_pointer: ?*const resource.ProbeRequest, out: ?*resource.Proof) callconv(.c) i32 {
        const self = state(pointer);
        const request = request_pointer.?;
        self.probes += 1;
        if (!request.expected.eql(self.stamp)) return resource.Status.stale_version;
        out.?.* = .{ .stamp = self.stamp, .target_id = request.target_id, .mode = request.mode, .head_hash = if (request.mode == @backingInt(resource.Mode.register_file)) @splat(0) else @splat(0x11), .content_hash = @splat(0x22), .path_hash = @splat(0x33), .byte_length = 72, .volume_serial = 9, .file_index = 10 };
        return abi.Status.ok;
    }

    fn reject(self: *Fake, sequence: u64, status: i32) resource.Outcome {
        return .{ .status = status, .disposition = @backingInt(resource.Disposition.rejected), .sequence = sequence, .stamp = self.stamp };
    }

    fn delivered(self: *const Fake, value: resource.Outcome) resource.Outcome {
        var outcome = value;
        if (self.reply_epoch) |epoch| {
            outcome.stamp.epoch_hi = epoch[0];
            outcome.stamp.epoch_lo = epoch[1];
        }
        if (self.reply_revision) |revision| outcome.stamp.revision = revision;
        return outcome;
    }

    fn submit(pointer: ?*anyopaque, request_pointer: ?*const resource.Request, out: ?*resource.Outcome) callconv(.c) i32 {
        const self = state(pointer);
        const request = request_pointer.?;
        self.submits += 1;
        const path = request.path.ptr.?[0..request.path.len];
        std.debug.assert(path.len <= self.received_path.len);
        @memcpy(self.received_path[0..path.len], path);
        self.received = request.*;
        self.received.?.path = .{ .ptr = &self.received_path, .len = path.len };
        if (request.proof.stamp.epoch_hi != self.stamp.epoch_hi or request.proof.stamp.epoch_lo != self.stamp.epoch_lo) {
            out.?.* = self.delivered(self.reject(request.sequence, resource.Status.wrong_epoch));
            return abi.Status.ok;
        }
        if (self.force_status) |status| {
            out.?.* = self.delivered(self.reject(request.sequence, status));
            return abi.Status.ok;
        }
        if (self.receipt) |previous| {
            if (previous.sequence == request.sequence and self.receipt_client[0] == request.client_hi and self.receipt_client[1] == request.client_lo) {
                if (!std.meta.eql(self.receipt_proof, request.proof) or !std.mem.eql(u8, self.receipt_path[0..self.receipt_path_len], path)) {
                    out.?.* = self.reject(request.sequence, resource.Status.request_conflict);
                    return abi.Status.ok;
                }
                out.?.* = self.delivered(previous);
                out.?.disposition = @backingInt(resource.Disposition.replayed);
                return abi.Status.ok;
            }
        }
        var outcome = if (!request.proof.stamp.eql(self.stamp))
            self.reject(request.sequence, resource.Status.stale_version)
        else blk: {
            if (self.execute_status == abi.Status.ok) {
                self.mutations += 1;
                self.stamp.revision += 1;
            }
            break :blk resource.Outcome{ .status = self.execute_status, .disposition = @backingInt(resource.Disposition.executed), .sequence = request.sequence, .stamp = self.stamp, .resource_id = if (self.execute_status != abi.Status.ok) 0 else if (request.proof.mode == @backingInt(resource.Mode.register_file)) 2 else request.proof.target_id };
        };
        self.receipt = outcome;
        self.receipt_proof = request.proof;
        self.receipt_client = .{ request.client_hi, request.client_lo };
        self.receipt_path_len = path.len;
        @memcpy(self.receipt_path[0..path.len], path);
        if (self.lose_response) {
            self.lose_response = false;
            return abi.Status.failed;
        }
        if (self.malformed_outcome) {
            self.malformed_outcome = false;
            outcome.struct_size = 0;
        }
        out.?.* = self.delivered(outcome);
        return abi.Status.ok;
    }

    fn api(self: *Fake) resource.Api {
        return .{ .context = self, .snapshot = snapshot, .probe = probe, .submit = submit };
    }
};

fn testClient(remote: *Fake, nonces: *Nonces) !Client {
    const api = remote.api();
    return Client.initApi(std.testing.allocator, &api, nonces.source());
}

test "resource client guards the Shell ABI before reading a new getter" {
    const Prefix = extern struct { struct_size: u32, abi_version: u32 };
    var old: Prefix align(@alignOf(abi.ShellApi)) = .{ .struct_size = @sizeOf(Prefix), .abi_version = abi.version - 1 };
    var nonces: Nonces = .{};
    try std.testing.expectError(error.InvalidShellApi, Client.init(std.testing.allocator, @ptrCast(&old), nonces.source()));
}

test "generic registration keeps its allocated identity across a lost reply" {
    var remote: Fake = .{ .lose_response = true };
    var nonces: Nonces = .{};
    var client = try testClient(&remote, &nonces);
    defer client.deinit();
    try client.refresh();
    try client.probe(0, .register_file, "C:/synthetic/notes.txt");
    try std.testing.expect(std.mem.allEqual(u8, &client.candidate().?.proof.head_hash, 0));
    try std.testing.expect((try client.submit()) == .unknown);
    try std.testing.expect(client.hasPending());
    const result = (try client.retry()).known;
    try std.testing.expectEqual(abi.Status.ok, result.outcome.status);
    try std.testing.expectEqual(@as(u64, 2), result.outcome.resource_id);
    try std.testing.expectEqual(@as([32]u8, @splat(0x22)), result.content_hash);
    try std.testing.expectEqual(@as(usize, 1), remote.mutations);
    try std.testing.expect(!client.hasPending());
}

test "resource snapshots publish complete owned views and allow revision zero and exhausted IDs" {
    var remote: Fake = .{};
    var nonces: Nonces = .{};
    var client = try testClient(&remote, &nonces);
    defer client.deinit();
    try client.refresh();
    try std.testing.expectEqualStrings("original.png", client.projection.view.findResource(1).?.label);
    try std.testing.expectEqual(@as(u64, 2), client.projection.next_id);
    remote.stamp.revision = 0;
    remote.text = "{\"format\":\"cutrans-resource-snapshot/1\",\"next_id\":1,\"folders\":[],\"resources\":[]}";
    try client.refresh();
    try std.testing.expectEqual(@as(u64, 0), client.projection.stamp.?.revision);
    remote.text = "{\"format\":\"cutrans-resource-snapshot/1\",\"next_id\":0,\"folders\":[{\"id\":18446744073709551615,\"parent_id\":0,\"label\":\"last\"}],\"resources\":[]}";
    try client.refresh();
    try std.testing.expectEqual(@as(u64, 0), client.projection.next_id);
    try std.testing.expectEqualStrings("last", client.projection.view.find(std.math.maxInt(u64)).?.label);
}

test "snapshot races short buffers and invalid JSON never replace a good projection" {
    var remote: Fake = .{};
    var nonces: Nonces = .{};
    var client = try testClient(&remote, &nonces);
    defer client.deinit();
    try client.refresh();
    const old_stamp = client.projection.stamp.?;
    const old_label = client.projection.view.items[0].label.ptr;
    remote.change_after_query = true;
    try std.testing.expectError(error.ResourceSnapshotChanged, client.refresh());
    remote.short_read = true;
    try std.testing.expectError(error.ResourceSnapshotReadFailed, client.refresh());
    remote.short_read = false;
    remote.text = "not JSON";
    if (client.refresh()) |_| return error.ExpectedInvalidSnapshot else |_| {}
    try std.testing.expect(client.projection.stamp.?.eql(old_stamp));
    try std.testing.expectEqual(old_label, client.projection.view.items[0].label.ptr);
    try std.testing.expectEqualStrings("original.png", client.projection.view.items[0].label);
}

test "unknown requests own proof path nonce and sequence while projections continue to refresh" {
    var remote = Fake{ .lose_response = true };
    var nonces: Nonces = .{};
    var client = try testClient(&remote, &nonces);
    defer client.deinit();
    try client.refresh();
    const mutable = try std.testing.allocator.dupe(u8, test_path);
    defer std.testing.allocator.free(mutable);
    try client.probe(1, .adopt, mutable);
    const proof = client.candidate().?.proof;
    @memset(mutable, 'x');
    try std.testing.expect((try client.submit()) == .unknown);
    try std.testing.expect(client.hasPending());
    const first_client = client.pending_request.?.client_id;
    try client.refresh();
    try std.testing.expectError(error.ResourceResultUnknown, client.probe(1, .relocate, test_path));
    try std.testing.expectError(error.ResourceResultUnknown, client.submit());
    const settled = (try client.retry()).known;
    try std.testing.expectEqual(@as(u32, @backingInt(resource.Disposition.replayed)), settled.outcome.disposition);
    try std.testing.expectEqualDeep(proof, remote.received.?.proof);
    try std.testing.expectEqualStrings(test_path, remote.received_path[0..remote.received.?.path.len]);
    try std.testing.expectEqual(first_client[0], remote.received.?.client_hi);
    try std.testing.expectEqual(first_client[1], remote.received.?.client_lo);
    try std.testing.expectEqual(@as(u64, 1), remote.received.?.sequence);
    try std.testing.expectEqual(@as(usize, 1), remote.mutations);
    try std.testing.expectEqual(@as(u64, 1), nonces.calls);
    try std.testing.expect(!client.hasPending());
    try std.testing.expectEqual(@as(u64, 2), client.next_sequence);
}

test "malformed outcomes stay pending and a definitive stale receipt consumes its sequence" {
    var remote = Fake{ .malformed_outcome = true };
    var nonces: Nonces = .{};
    var client = try testClient(&remote, &nonces);
    defer client.deinit();
    try client.refresh();
    try client.probe(1, .adopt, test_path);
    try std.testing.expect((try client.submit()) == .unknown);
    _ = (try client.retry()).known;
    try client.refresh();
    try client.probe(1, .relocate, test_path);
    remote.stamp.revision += 1;
    const stale = (try client.submit()).known;
    try std.testing.expectEqual(resource.Status.stale_version, stale.outcome.status);
    try std.testing.expect(!client.hasPending());
    try std.testing.expectEqual(@as(u64, 3), client.next_sequence);
    try std.testing.expectEqual(@as(usize, 1), remote.mutations);
}

test "success and refusal replies from another epoch or an older revision retain the exact pending intent" {
    for ([_]i32{ abi.Status.ok, resource.Status.candidate_changed }) |status| {
        for ([_]bool{ true, false }) |wrong_epoch| {
            var remote = Fake{ .execute_status = status, .reply_epoch = if (wrong_epoch) ClientId{ 90, 91 } else null, .reply_revision = if (wrong_epoch) null else 0 };
            var nonces: Nonces = .{};
            var client = try testClient(&remote, &nonces);
            defer client.deinit();
            try client.refresh();
            try client.probe(1, .adopt, test_path);
            const proof = client.candidate().?.proof;
            try std.testing.expect((try client.submit()) == .unknown);
            const identity = client.pending_request.?.client_id;
            try std.testing.expectEqualDeep(proof, client.pending_request.?.candidate.proof);
            try std.testing.expectEqualStrings(test_path, client.pending_request.?.candidate.path);
            try std.testing.expectEqual(@as(u64, 1), client.next_sequence);
            try std.testing.expectEqual(@as(u64, 1), nonces.calls);
            remote.reply_epoch = null;
            remote.reply_revision = null;
            const settled = (try client.retry()).known;
            try std.testing.expectEqual(status, settled.outcome.status);
            try std.testing.expectEqual(@as(u32, @backingInt(resource.Disposition.replayed)), settled.outcome.disposition);
            try std.testing.expectEqualDeep(identity, settled.client_id);
            try std.testing.expectEqualDeep(proof, remote.received.?.proof);
            try std.testing.expectEqualStrings(test_path, remote.received_path[0..remote.received.?.path.len]);
            try std.testing.expectEqual(@as(u64, 2), client.next_sequence);
            try std.testing.expectEqual(@as(u64, 1), nonces.calls);
            try std.testing.expect(!client.hasPending());
        }
    }
}

test "only wrong epoch may settle with a new incarnation and a lower revision" {
    var remote = Fake{ .force_status = resource.Status.receipt_expired, .reply_epoch = .{ 90, 91 }, .reply_revision = 0 };
    var nonces: Nonces = .{};
    var client = try testClient(&remote, &nonces);
    defer client.deinit();
    try client.refresh();
    try client.probe(1, .adopt, test_path);
    try std.testing.expect((try client.submit()) == .unknown);
    try std.testing.expect(client.hasPending() and client.identity != null);
    try std.testing.expectEqual(@as(u64, 1), client.next_sequence);
    remote.force_status = resource.Status.wrong_epoch;
    const settled = (try client.retry()).known;
    try std.testing.expect(settled.previous_result_uncertain);
    try std.testing.expectEqual(@as(u64, 90), settled.outcome.stamp.epoch_hi);
    try std.testing.expectEqual(@as(u64, 0), settled.outcome.stamp.revision);
    try std.testing.expect(!client.hasPending() and client.identity == null);
    try std.testing.expectEqual(@as(u64, 1), nonces.calls);
}

test "epoch expiry conflict and bad sequence settle without automatically replaying a new identity" {
    for ([_]i32{ resource.Status.wrong_epoch, resource.Status.receipt_expired, resource.Status.request_conflict, resource.Status.bad_sequence }) |status| {
        var remote = Fake{ .force_status = status };
        var nonces: Nonces = .{};
        var client = try testClient(&remote, &nonces);
        defer client.deinit();
        try client.refresh();
        try client.probe(1, .adopt, test_path);
        const settled = (try client.submit()).known;
        try std.testing.expectEqual(status == resource.Status.wrong_epoch or status == resource.Status.receipt_expired, settled.previous_result_uncertain);
        try std.testing.expect(!client.hasPending() and client.identity == null);
        try std.testing.expectEqual(@as(u64, 1), client.next_sequence);
        try std.testing.expectEqual(@as(u64, 1), nonces.calls);
        try std.testing.expectEqual(@as(usize, 1), remote.submits);
        try std.testing.expectError(error.NoPendingResourceRequest, client.retry());
        remote.force_status = null;
        try client.refresh();
        try client.probe(1, .adopt, test_path);
        try std.testing.expectEqual(@as(u64, 1), nonces.calls);
        _ = (try client.submit()).known;
        try std.testing.expectEqual(@as(u64, 2), nonces.calls);
        try std.testing.expectEqual(@as(u64, 1), remote.received.?.sequence);
    }
}

test "client limits do not consume a sequence and committed results outlive projection failure" {
    var remote = Fake{ .force_status = resource.Status.client_limit };
    var nonces: Nonces = .{};
    var client = try testClient(&remote, &nonces);
    defer client.deinit();
    try client.refresh();
    try client.probe(1, .adopt, test_path);
    _ = (try client.submit()).known;
    try std.testing.expectEqual(@as(u64, 1), client.next_sequence);
    remote.force_status = null;
    try client.probe(1, .adopt, test_path);
    const committed = (try client.submit()).known;
    try std.testing.expectEqual(abi.Status.ok, committed.outcome.status);
    remote.fail_query = true;
    try std.testing.expectError(error.ResourceSnapshotQueryFailed, client.refresh());
    try std.testing.expect(!client.hasPending());
    try std.testing.expectEqual(abi.Status.ok, client.lastSettlement().?.outcome.status);
    try std.testing.expectEqual(@as(usize, 2), remote.submits);
    try std.testing.expectEqual(@as(usize, 1), remote.mutations);
}

test "invalid local candidate input cannot create an unretryable pending request" {
    var remote: Fake = .{};
    var nonces: Nonces = .{};
    var client = try testClient(&remote, &nonces);
    defer client.deinit();
    try client.refresh();
    try std.testing.expectError(error.InvalidCandidate, client.probe(1, .adopt, "relative.png"));
    try std.testing.expectError(error.InvalidCandidate, client.probe(1, .adopt, ""));
    try std.testing.expectEqual(@as(usize, 0), remote.probes);
    try client.probe(1, .adopt, test_path);
    client.prepared.?.proof.struct_size = 0;
    try std.testing.expectError(error.InvalidCandidate, client.submit());
    try std.testing.expect(!client.hasPending());
    try std.testing.expectEqual(@as(usize, 0), remote.submits);
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    var remote: Fake = .{};
    var nonces: Nonces = .{};
    const api = remote.api();
    var client = try Client.initApi(allocator, &api, nonces.source());
    defer client.deinit();
    try client.refresh();
    try client.probe(1, .adopt, test_path);
    _ = try client.submit();
}

test "resource projection parsing and candidate ownership unwind allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}
