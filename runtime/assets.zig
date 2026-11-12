const std = @import("std");
const vne = @import("vne");
const RuntimeContext = @import("context.zig").Context;
const command = @import("vne").command;
const image = @import("image.zig");
const storage = @import("storage.zig");

pub const SourceKind = enum { pack, external, snapshot, library };
pub const SourceIdentity = union(enum) {
    file: @import("ports").file_identity.Identity,
    snapshot: [32]u8,
    library: u64,
};

pub const Source = struct {
    kind: SourceKind,
    uri: []u8,
    identity: ?SourceIdentity,
    content_hash: [32]u8,

    fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        self.uri = &.{};
    }
};

pub const Asset = struct {
    handle: u64,
    source: Source,
    bytes: []u8,
    leases: u32,
    source_status: vne.assets.SourceStatus = .unchecked,
    observed_binding_hash: [32]u8 = @splat(0),

    fn deinit(self: *Asset, allocator: std.mem.Allocator) void {
        self.source.deinit(allocator);
        allocator.free(self.bytes);
        self.bytes = &.{};
    }
};

pub const OwnedSource = struct {
    source: Source,
    bytes: []u8,

    pub fn deinit(self: *OwnedSource, allocator: std.mem.Allocator) void {
        self.source.deinit(allocator);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const Manifest = struct {
    format: []const u8,
    snapshot_id: []const u8,
    content: struct {
        path: []const u8,
        byteLength: u64,
        sha256: []const u8,
    },
    provenance: struct {
        source_kind: []const u8,
        source: []const u8,
    },
};

fn hash(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn hex(digest: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

fn readFile(ctx: *RuntimeContext, text: []const u8, uri: vne.uri.Uri, resolved: vne.mounts.Resolved) !OwnedSource {
    const kind: SourceKind = switch (uri.root) {
        .pack => .pack,
        .session => .snapshot,
        else => .external,
    };
    const observed: @import("ports").file_identity.Read = if (kind == .external) blk: {
        try ctx.external_sources.requireVerified(uri);
        break :blk try @import("ports").file_identity.readStable(ctx.allocator, ctx.io.?, resolved.path, 16 * 1024 * 1024);
    } else .{
        .bytes = try std.Io.Dir.cwd().readFileAlloc(ctx.io.?, resolved.path, ctx.allocator, .limited(16 * 1024 * 1024)),
        .identity = null,
    };
    const bytes = observed.bytes;
    errdefer ctx.allocator.free(bytes);
    const file_identity = observed.identity;
    const digest = hash(bytes);
    if (kind == .external) try ctx.external_sources.noteRead(ctx, uri, file_identity, digest);
    return .{
        .source = .{
            .kind = kind,
            .uri = try ctx.allocator.dupe(u8, text),
            .identity = switch (kind) {
                .pack => null,
                .snapshot => .{ .snapshot = digest },
                .external => if (file_identity) |value| .{ .file = value } else null,
                .library => unreachable,
            },
            .content_hash = digest,
        },
        .bytes = bytes,
    };
}

fn readSnapshot(ctx: *RuntimeContext, text: []const u8, resolved: vne.mounts.Resolved, dir: std.Io.Dir) !OwnedSource {
    _ = resolved;
    const manifest_text = try dir.readFileAlloc(ctx.io.?, "snapshot.json", ctx.allocator, .limited(64 * 1024));
    defer ctx.allocator.free(manifest_text);
    const parsed = try std.json.parseFromSlice(Manifest, ctx.allocator, manifest_text, .{ .ignore_unknown_fields = false, .allocate = .alloc_always });
    defer parsed.deinit();
    const manifest = parsed.value;
    if (!std.mem.eql(u8, manifest.format, "cutrans-content-snapshot/1") or
        !std.mem.eql(u8, manifest.content.path, "content.bin")) return error.InvalidSnapshot;
    _ = std.meta.stringToEnum(SourceKind, manifest.provenance.source_kind) orelse return error.InvalidSnapshot;
    _ = try vne.uri.parse(manifest.provenance.source);
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, manifest.snapshot_id) catch return error.InvalidSnapshot;
    var declared: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&declared, manifest.content.sha256) catch return error.InvalidSnapshot;
    if (!std.mem.eql(u8, &expected, &declared)) return error.InvalidSnapshot;
    const bytes = try dir.readFileAlloc(ctx.io.?, manifest.content.path, ctx.allocator, .limited(16 * 1024 * 1024));
    errdefer ctx.allocator.free(bytes);
    const actual = hash(bytes);
    if (bytes.len != manifest.content.byteLength or !std.mem.eql(u8, &actual, &expected)) return error.SnapshotContentMismatch;
    return .{
        .source = .{
            .kind = .snapshot,
            .uri = try ctx.allocator.dupe(u8, text),
            .identity = .{ .snapshot = expected },
            .content_hash = actual,
        },
        .bytes = bytes,
    };
}

fn readSource(ctx: *RuntimeContext, text: []const u8) !OwnedSource {
    const uri = try vne.uri.parse(text);
    if (uri.root == .library) {
        const id = std.fmt.parseInt(u64, uri.body, 10) catch return error.InvalidResourcePath;
        return ctx.library.read(ctx, id);
    }
    const resolved = try ctx.mounts.resolveAlloc(ctx.allocator, uri);
    defer ctx.allocator.free(resolved.path);
    const io = ctx.io orelse return error.IoNotReady;
    // A persistent external grant authorizes a file identity. Replacing its
    // pathname with a snapshot directory must not switch that authorization
    // into the separate directory-snapshot read path.
    if (uri.root == .external and try ctx.external_sources.hasRecord(uri)) {
        try ctx.external_sources.requireVerified(uri);
        return readFile(ctx, text, uri, resolved);
    }
    var dir = std.Io.Dir.openDirAbsolute(io, resolved.path, .{}) catch |err| {
        if (err == error.NotDir) return readFile(ctx, text, uri, resolved);
        return err;
    };
    defer dir.close(io);
    return readSnapshot(ctx, text, resolved, dir);
}

pub fn readStandalone(ctx: *RuntimeContext, uri: []const u8) anyerror!OwnedSource {
    return readVersion(ctx, uri, null);
}

/// A bound library Source resolves its exact retained version before considering
/// the current reference. Reading never creates retained bytes. Other Source
/// kinds keep their existing resolution and must match the requested digest.
pub fn readVersion(ctx: *RuntimeContext, text: []const u8, expected: ?[32]u8) anyerror!OwnedSource {
    const uri = try vne.uri.parse(text);
    var loaded = if (uri.root == .library and expected != null) blk: {
        const id = std.fmt.parseInt(u64, uri.body, 10) catch return error.InvalidResourcePath;
        break :blk try ctx.library.readVersion(ctx, id, expected.?);
    } else try readSource(ctx, text);
    errdefer loaded.deinit(ctx.allocator);
    if (expected) |digest| if (!std.mem.eql(u8, &digest, &loaded.source.content_hash)) return error.SourceContentMismatch;
    return loaded;
}

pub const Workspace = struct {
    context: ?*RuntimeContext = null,
    items: [16]Asset = undefined,
    count: usize = 0,
    next_handle: u64 = 1,
    total_bytes: usize = 0,
    revision: u64 = 0,

    pub fn deinit(self: *Workspace) void {
        for (self.items[0..self.count]) |*asset| asset.deinit(self.allocator());
        self.* = .{};
    }

    fn allocator(self: *const Workspace) std.mem.Allocator {
        return self.context.?.allocator;
    }

    pub fn open(self: *Workspace, ctx: *RuntimeContext, uri: []const u8) !u64 {
        return self.openVersion(ctx, uri, null);
    }

    /// Only a Resource identity and its exact head identify a resident match.
    /// No source resolution, hashing, lease acquisition or publication occurs.
    pub fn findResourceHead(self: *const Workspace, id: u64, digest: [32]u8) ?*const Asset {
        for (self.items[0..self.count]) |*asset| {
            const identity = asset.source.identity orelse continue;
            switch (identity) {
                .library => |resource_id| {
                    if (resource_id == id and std.mem.eql(u8, &digest, &asset.source.content_hash)) return asset;
                },
                else => {},
            }
        }
        return null;
    }

    /// Ensure one root Station lease for a current Resource head. Repeating
    /// the same tuple after a lost reply never accumulates remote leases.
    /// Strict fixed-version consumers continue to use openVersion/readVersion.
    pub fn ensureResource(self: *Workspace, ctx: *RuntimeContext, id: u64, expected: [32]u8) !u64 {
        if (self.context) |existing| if (existing != ctx) return error.WorkspaceContextMismatch;
        const resource = ctx.library.get(id) orelse return error.ResourceNotFound;
        if (!std.mem.eql(u8, &expected, &resource.content_hash)) return error.SourceContentMismatch;
        if (self.findResourceHead(id, expected)) |asset| return asset.handle;
        _ = std.math.add(u64, self.revision, 1) catch return error.AssetRevisionExhausted;
        var buffer: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buffer, "library://{d}", .{id});
        return self.openVersion(ctx, uri, null);
    }

    /// Generic file acquisition preserves the Resource head and does not
    /// decode media or write Source observation records. A root Station lease
    /// is established at most once for the current (Resource, digest) tuple.
    pub fn ensureFile(self: *Workspace, ctx: *RuntimeContext, id: u64, expected: [32]u8) !u64 {
        if (self.context) |existing| if (existing != ctx) return error.WorkspaceContextMismatch;
        const resource = ctx.library.get(id) orelse return error.ResourceNotFound;
        if (!std.mem.eql(u8, &expected, &resource.content_hash)) return error.SourceContentMismatch;
        if (self.findResourceHead(id, expected)) |asset| return asset.handle;
        _ = std.math.add(u64, self.revision, 1) catch return error.AssetRevisionExhausted;
        const loaded = try ctx.library.readFile(ctx, id);
        self.context = ctx;
        return self.admitSource(ctx, loaded);
    }

    /// An observation only describes the binding that was actually checked.
    /// Logical rename/move do not invalidate it; detach/rebind/restore can.
    pub fn visibleSourceStatus(ctx: *const RuntimeContext, asset: *const Asset) vne.assets.SourceStatus {
        if (asset.source_status == .unchecked) return .unchecked;
        const identity = asset.source.identity orelse return .unchecked;
        const id = switch (identity) {
            .library => |value| value,
            else => return .unchecked,
        };
        const resource = ctx.library.get(id) orelse return .superseded;
        const current_binding = resourceBindingHash(resource);
        if (!std.mem.eql(u8, &current_binding, &asset.observed_binding_hash)) return .unchecked;
        return asset.source_status;
    }

    /// Explicitly observe an already loaded library object. The caller holds
    /// the session owner; observation never adopts a head or replaces bytes.
    pub fn checkResource(self: *Workspace, ctx: *RuntimeContext, handle: u64) !void {
        if (self.context) |existing| if (existing != ctx) return error.WorkspaceContextMismatch;
        const index = self.find(handle) orelse return error.AssetNotFound;
        const asset = &self.items[index];
        if (asset.source.kind != .library) return error.InvalidResourceState;
        const identity = asset.source.identity orelse return error.InvalidResourceState;
        const id = switch (identity) {
            .library => |value| value,
            else => return error.InvalidResourceState,
        };
        // Reserve publication before any IO. Even a failed observation must
        // not discover a result which cannot be represented in the projection.
        const next_revision = std.math.add(u64, self.revision, 1) catch return error.AssetRevisionExhausted;
        const resource = ctx.library.get(id);
        const binding = if (resource) |value| resourceBindingHash(value) else @as([32]u8, @splat(0));
        const status: vne.assets.SourceStatus = if (resource == null or
            !std.mem.eql(u8, &resource.?.content_hash, &asset.source.content_hash)) .superseded else observed: {
            const digest = switch (resource.?.kind) {
                .reference => blk: {
                    var source = ctx.external_sources.observe(ctx, resource.?.source_uri) catch |err| {
                        std.debug.print("CUTRANS_ASSET_CHECK asset={d} source_error={s}\n", .{ handle, @errorName(err) });
                        break :observed sourceErrorStatus(err);
                    };
                    defer source.deinit(ctx.allocator);
                    break :blk source.digest;
                },
                .owned => blk: {
                    var source = ctx.library.read(ctx, id) catch |err| {
                        std.debug.print("CUTRANS_ASSET_CHECK asset={d} source_error={s}\n", .{ handle, @errorName(err) });
                        break :observed sourceErrorStatus(err);
                    };
                    defer source.deinit(ctx.allocator);
                    break :blk source.source.content_hash;
                },
            };
            break :observed if (std.mem.eql(u8, &digest, &asset.source.content_hash)) .unchanged else .content_changed;
        };
        if (asset.source_status == status and std.mem.eql(u8, &binding, &asset.observed_binding_hash)) return;
        asset.source_status = status;
        asset.observed_binding_hash = binding;
        self.revision = next_revision;
        std.debug.print("CUTRANS_ASSET_CHECK asset={d} status={s}\n", .{ handle, @tagName(status) });
    }

    pub fn openVersion(self: *Workspace, ctx: *RuntimeContext, uri: []const u8, expected: ?[32]u8) !u64 {
        if (self.context) |existing| {
            if (existing != ctx) return error.WorkspaceContextMismatch;
        } else {
            self.context = ctx;
        }
        const loaded = try readVersion(ctx, uri, expected);
        return self.admitSource(ctx, loaded);
    }

    /// Takes ownership of complete encoded/raw bytes on success or failure.
    /// Strict and generic readers choose their own Source policy before here.
    fn admitSource(self: *Workspace, ctx: *RuntimeContext, initial: OwnedSource) !u64 {
        var loaded = initial;
        errdefer loaded.deinit(ctx.allocator);
        for (self.items[0..self.count]) |*asset| {
            if (asset.source.kind != loaded.source.kind or !std.mem.eql(u8, &asset.source.content_hash, &loaded.source.content_hash)) continue;
            const same_identity = if (asset.source.identity) |left| switch (left) {
                .file => |left_file| if (loaded.source.identity) |right| switch (right) {
                    .file => |right_file| left_file.volume_serial == right_file.volume_serial and left_file.file_index == right_file.file_index,
                    else => false,
                } else false,
                .snapshot => |left_snapshot| if (loaded.source.identity) |right| switch (right) {
                    .snapshot => |right_snapshot| std.mem.eql(u8, &left_snapshot, &right_snapshot),
                    else => false,
                } else false,
                .library => |left_library| if (loaded.source.identity) |right| switch (right) {
                    .library => |right_library| left_library == right_library,
                    else => false,
                } else false,
            } else std.mem.eql(u8, asset.source.uri, loaded.source.uri);
            if (!same_identity) continue;
            if (asset.leases == std.math.maxInt(u32)) return error.AssetLeaseLimit;
            asset.leases += 1;
            asset.source.deinit(ctx.allocator);
            asset.source = loaded.source;
            allocatorFree(ctx, loaded.bytes);
            loaded.source.uri = &.{};
            self.revision += 1;
            std.debug.print("CUTRANS_ASSET_OPEN asset={d} source={s} leases={d}\n", .{ asset.handle, asset.source.uri, asset.leases });
            return asset.handle;
        }
        if (self.count == self.items.len) return error.AssetWorkspaceFull;
        if (self.total_bytes + loaded.bytes.len > 64 * 1024 * 1024) return error.AssetWorkspaceBudgetExceeded;
        const handle = self.next_handle;
        self.next_handle += 1;
        self.items[self.count] = .{ .handle = handle, .source = loaded.source, .bytes = loaded.bytes, .leases = 1 };
        self.count += 1;
        self.total_bytes += loaded.bytes.len;
        loaded.source.uri = &.{};
        loaded.bytes = &.{};
        self.revision += 1;
        std.debug.print("CUTRANS_ASSET_OPEN asset={d} source={s} leases=1\n", .{ handle, self.items[self.count - 1].source.uri });
        return handle;
    }

    pub fn release(self: *Workspace, handle: u64) !void {
        const index = self.find(handle) orelse return error.AssetNotFound;
        const asset = &self.items[index];
        asset.leases -= 1;
        self.revision += 1;
        std.debug.print("CUTRANS_ASSET_RELEASE asset={d} leases={d}\n", .{ handle, asset.leases });
        if (asset.leases != 0) return;
        self.total_bytes -= asset.bytes.len;
        asset.deinit(self.allocator());
        self.count -= 1;
        if (index != self.count) self.items[index] = self.items[self.count];
    }

    pub const Preview = struct { width: u32, height: u32 };

    pub fn preview(self: *Workspace, handle: u64) !Preview {
        const asset = try self.get(handle);
        var decoded = try image.decode(self.allocator(), asset.bytes);
        defer decoded.deinit(self.allocator());
        std.debug.print("CUTRANS_ASSET_PREVIEW asset={d} kind=image width={d} height={d} coverage=complete\n", .{ handle, decoded.width, decoded.height });
        return .{ .width = decoded.width, .height = decoded.height };
    }

    pub fn get(self: *Workspace, handle: u64) !*const Asset {
        const index = self.find(handle) orelse return error.AssetNotFound;
        return &self.items[index];
    }

    pub fn exportSnapshot(self: *Workspace, handle: u64, destination: []const u8) !void {
        const index = self.find(handle) orelse return error.AssetNotFound;
        const asset = &self.items[index];
        const uri = try vne.uri.parse(destination);
        const resolved = try self.mounts().resolveAlloc(self.allocator(), uri);
        defer self.allocator().free(resolved.path);
        if (resolved.access != .read_write) return error.ReadOnlyResource;
        const io_value = self.io() orelse return error.IoNotReady;
        try std.Io.Dir.cwd().createDirPath(io_value, resolved.path);
        var dir = try std.Io.Dir.openDirAbsolute(io_value, resolved.path, .{});
        defer dir.close(io_value);
        const digest = hex(asset.source.content_hash);
        const manifest_text = try self.manifest(asset, digest);
        defer self.allocator().free(manifest_text);
        if (dir.readFileAlloc(io_value, "snapshot.json", self.allocator(), .limited(64 * 1024))) |existing| {
            defer self.allocator().free(existing);
            if (!std.mem.eql(u8, existing, manifest_text)) return error.SnapshotDestinationConflict;
            const existing_bytes = try dir.readFileAlloc(io_value, "content.bin", self.allocator(), .limited(16 * 1024 * 1024));
            defer self.allocator().free(existing_bytes);
            if (!std.mem.eql(u8, existing_bytes, asset.bytes)) return error.SnapshotDestinationConflict;
            std.debug.print("CUTRANS_ASSET_EXPORT asset={d} snapshot={s} path={s}\n", .{ handle, digest, destination });
            return;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
        const content_exists = blk: {
            dir.access(io_value, "content.bin", .{}) catch |err| {
                if (err == error.FileNotFound) break :blk false;
                return err;
            };
            break :blk true;
        };
        if (content_exists) return error.SnapshotDestinationConflict;
        try storage.writeAtomic(dir, io_value, "content.bin", asset.bytes);
        try storage.writeAtomic(dir, io_value, "snapshot.json", manifest_text);
        std.debug.print("CUTRANS_ASSET_EXPORT asset={d} snapshot={s} path={s}\n", .{ handle, digest, destination });
    }

    fn manifest(self: *Workspace, asset: *const Asset, digest: [64]u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator(), "{{\"format\":\"cutrans-content-snapshot/1\",\"snapshot_id\":\"{s}\",\"content\":{{\"path\":\"content.bin\",\"byteLength\":{d},\"sha256\":\"{s}\"}},\"provenance\":{{\"source_kind\":\"{s}\",\"source\":{f}}}}}\n", .{
            digest,
            asset.bytes.len,
            digest,
            @tagName(asset.source.kind),
            std.json.fmt(asset.source.uri, .{}),
        });
    }

    fn mounts(self: *Workspace) *const vne.mounts.Table {
        return &self.context.?.mounts;
    }

    fn io(self: *const Workspace) ?std.Io {
        return self.context.?.io;
    }

    fn find(self: *const Workspace, handle: u64) ?usize {
        for (self.items[0..self.count], 0..) |asset, index| {
            if (asset.handle == handle) return index;
        }
        return null;
    }
};

fn allocatorFree(ctx: *RuntimeContext, bytes: []u8) void {
    ctx.allocator.free(bytes);
}

fn sourceErrorStatus(err: anyerror) vne.assets.SourceStatus {
    return switch (err) {
        error.FileNotFound => .missing,
        error.SourceIdentityChanged => .identity_changed,
        error.LegacyExternalIdentityUnverified => .unverified,
        error.ResourceContentChanged, error.SourceContentMismatch, error.ResourceVersionContentMismatch => .content_changed,
        else => .unavailable,
    };
}

fn resourceBindingHash(resource: *const @import("resource_library.zig").Resource) [32]u8 {
    var state = std.crypto.hash.sha2.Sha256.init(.{});
    var number: [8]u8 = undefined;
    std.mem.writeInt(u64, &number, resource.id, .little);
    state.update(&number);
    const kind: u8 = @intCast(@backingInt(resource.kind));
    state.update(&.{kind});
    std.mem.writeInt(u64, &number, resource.source_uri.len, .little);
    state.update(&number);
    state.update(resource.source_uri);
    state.update(&resource.content_hash);
    var digest: [32]u8 = undefined;
    state.final(&digest);
    return digest;
}

fn onlyId(text: ?[]const u8) !u64 {
    const value = std.mem.trim(u8, text orelse return error.InvalidArguments, " \t");
    if (value.len == 0) return error.InvalidArguments;
    return std.fmt.parseInt(u64, value, 10) catch return error.InvalidArguments;
}

fn exportArgs(text: ?[]const u8) !struct { id: u64, destination: []const u8 } {
    const value = std.mem.trim(u8, text orelse return error.InvalidArguments, " \t");
    const split = std.mem.indexOfScalar(u8, value, ' ') orelse return error.InvalidArguments;
    const id = std.fmt.parseInt(u64, value[0..split], 10) catch return error.InvalidArguments;
    const destination = std.mem.trim(u8, value[split + 1 ..], " \t");
    if (destination.len == 0) return error.InvalidArguments;
    return .{ .id = id, .destination = destination };
}

fn ensureArgs(text: ?[]const u8) !struct { id: u64, digest: [32]u8 } {
    var values = std.mem.tokenizeAny(u8, text orelse return error.InvalidArguments, " \t");
    const id = std.fmt.parseInt(u64, values.next() orelse return error.InvalidArguments, 10) catch return error.InvalidArguments;
    const digest_text = values.next() orelse return error.InvalidArguments;
    if (id == 0 or digest_text.len != 64 or values.next() != null) return error.InvalidArguments;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, digest_text) catch return error.InvalidArguments;
    return .{ .id = id, .digest = digest };
}

pub fn dispatch(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    if (std.mem.eql(u8, c.name, "resource.acquire")) {
        const args = ensureArgs(c.arg) catch return .failure(.invalid_arguments);
        _ = ctx.assets.ensureFile(ctx, args.id, args.digest) catch |err| return switch (err) {
            error.ManagedSourceForbidden, error.LinkedSourceUnsupported => .failure(.permission_denied),
            error.ResourceNotFound, error.SourceContentMismatch, error.ResourceContentChanged, error.LegacyExternalIdentityUnverified, error.SourceIdentityChanged => .failure(.invalid_state),
            error.AssetWorkspaceFull, error.AssetWorkspaceBudgetExceeded => .failure(.queue_full),
            else => .failure(.failed),
        };
        return .accepted;
    }
    if (std.mem.eql(u8, c.name, "asset.ensure")) {
        const args = ensureArgs(c.arg) catch return .failure(.invalid_arguments);
        _ = ctx.assets.ensureResource(ctx, args.id, args.digest) catch |err| return switch (err) {
            error.ResourceNotFound, error.SourceContentMismatch, error.LegacyExternalIdentityUnverified => .failure(.invalid_state),
            error.AssetWorkspaceFull, error.AssetWorkspaceBudgetExceeded => .failure(.queue_full),
            else => .failure(.failed),
        };
        return .accepted;
    }
    if (std.mem.eql(u8, c.name, "asset.check")) {
        const handle = onlyId(c.arg) catch return .failure(.invalid_arguments);
        ctx.assets.checkResource(ctx, handle) catch |err| return switch (err) {
            error.AssetNotFound, error.InvalidResourceState => .failure(.invalid_state),
            else => .failure(.failed),
        };
        return .success;
    }
    if (std.mem.eql(u8, c.name, "asset.open")) {
        const uri = c.arg orelse return .failure(.invalid_arguments);
        _ = ctx.assets.open(ctx, uri) catch |err| return switch (err) {
            error.AssetWorkspaceFull, error.AssetWorkspaceBudgetExceeded => .failure(.queue_full),
            error.LegacyExternalIdentityUnverified => .failure(.invalid_state),
            error.InvalidResourcePath, error.NotVirtualUri, error.InvalidExternalGrant => .failure(.invalid_arguments),
            else => .failure(.failed),
        };
        return .accepted;
    }
    if (std.mem.eql(u8, c.name, "asset.preview")) {
        const id = onlyId(c.arg) catch return .failure(.invalid_arguments);
        _ = ctx.assets.preview(id) catch |err| return switch (err) {
            error.AssetNotFound => .failure(.invalid_state),
            else => .failure(.failed),
        };
        return .success;
    }
    if (std.mem.eql(u8, c.name, "asset.export")) {
        const args = exportArgs(c.arg) catch return .failure(.invalid_arguments);
        ctx.assets.exportSnapshot(args.id, args.destination) catch |err| return switch (err) {
            error.AssetNotFound => .failure(.invalid_state),
            error.ReadOnlyResource => .failure(.permission_denied),
            error.SnapshotDestinationConflict => .failure(.invalid_state),
            else => .failure(.failed),
        };
        return .success;
    }
    if (std.mem.eql(u8, c.name, "asset.release")) {
        const id = onlyId(c.arg) catch return .failure(.invalid_arguments);
        ctx.assets.release(id) catch return .failure(.invalid_state);
        return .success;
    }
    if (std.mem.eql(u8, c.name, "asset.list")) {
        for (ctx.assets.items[0..ctx.assets.count]) |asset| {
            std.debug.print("asset={d} leases={d} bytes={d} source={s} source_status={s}\n", .{ asset.handle, asset.leases, asset.bytes.len, asset.source.uri, @tagName(Workspace.visibleSourceStatus(ctx, &asset)) });
        }
        return .success;
    }
    return .failure(.unknown_command);
}

fn fixture(ctx: *RuntimeContext, root: []const u8, resource: []const u8, data: []const u8) !void {
    _ = root;
    ctx.init(std.testing.allocator);
    ctx.io = std.testing.io;
    ctx.paths = try @import("paths.zig").Paths.fromDirs(std.testing.allocator, .development, resource, data);
    try @import("mounts.zig").configure(ctx);
}

test "asset workspace reuses sources exports independent snapshots and rejects tampering" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ resource, "assets/examples/source.png" });
    defer std.testing.allocator.free(source_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(source_path).?);
    var pixels = [_]u8{ 1, 2, 3, 255 };
    try image.savePngExternal(std.testing.allocator, std.testing.io, source_path, .{ .width = 1, .height = 1, .pixels = &pixels });
    var ctx: RuntimeContext = undefined;
    try fixture(&ctx, root, resource, data);
    defer ctx.deinit();
    const source_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, source_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(source_bytes);
    const first = try ctx.assets.open(&ctx, "pack://assets/examples/source.png");
    const second = try ctx.assets.open(&ctx, "pack://assets/examples/source.png");
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), ctx.assets.count);
    var wrong_hash = (try ctx.assets.get(first)).source.content_hash;
    wrong_hash[0] ^= 1;
    const before_failed_read = ctx.assets.revision;
    try std.testing.expectError(error.SourceContentMismatch, ctx.assets.openVersion(&ctx, "pack://assets/examples/source.png", wrong_hash));
    try std.testing.expectEqual(@as(u32, 2), (try ctx.assets.get(first)).leases);
    try std.testing.expectEqual(before_failed_read, ctx.assets.revision);
    _ = try ctx.assets.preview(first);
    try ctx.assets.exportSnapshot(first, "session://snapshots/one");
    try ctx.assets.exportSnapshot(first, "session://snapshots/one");
    try ctx.assets.release(first);
    try ctx.assets.release(second);
    try std.testing.expectEqual(@as(usize, 0), ctx.assets.count);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, source_path);
    const restored = try ctx.assets.open(&ctx, "session://snapshots/one");
    try std.testing.expectEqual(@as(u64, 2), restored);
    _ = try ctx.assets.preview(restored);
    const snapshot_content = try std.fs.path.join(std.testing.allocator, &.{ data, "snapshots/one/content.bin" });
    defer std.testing.allocator.free(snapshot_content);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, snapshot_content, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, source_bytes, bytes);
    try ctx.assets.release(restored);
    const tampered = try std.fs.path.join(std.testing.allocator, &.{ data, "snapshots/one/content.bin" });
    defer std.testing.allocator.free(tampered);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tampered, .data = "tampered" });
    try std.testing.expectError(error.SnapshotContentMismatch, ctx.assets.open(&ctx, "session://snapshots/one"));
}

test "external Station sources with equal hashes keep distinct real file identities" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const resource = try std.fs.path.join(allocator, &.{ root, "resources" });
    defer allocator.free(resource);
    const data = try std.fs.path.join(allocator, &.{ root, "data" });
    defer allocator.free(data);
    const first_path = try std.fs.path.join(allocator, &.{ root, "first.bin" });
    defer allocator.free(first_path);
    const second_path = try std.fs.path.join(allocator, &.{ root, "second.bin" });
    defer allocator.free(second_path);
    try tmp.dir.createDir(io, "resources", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "first.bin", .data = "identical encoded bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "second.bin", .data = "identical encoded bytes" });
    var ctx: RuntimeContext = undefined;
    try fixture(&ctx, root, resource, data);
    defer ctx.deinit();
    const first_id = try ctx.mounts.grantExternal(allocator, first_path, .read_only);
    const second_id = try ctx.mounts.grantExternal(allocator, second_path, .read_only);
    var first_buffer: [64]u8 = undefined;
    var second_buffer: [64]u8 = undefined;
    const first_uri = try std.fmt.bufPrint(&first_buffer, "external://{d}", .{first_id});
    const second_uri = try std.fmt.bufPrint(&second_buffer, "external://{d}", .{second_id});
    const first = try ctx.assets.open(&ctx, first_uri);
    const second = try ctx.assets.open(&ctx, second_uri);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(usize, 2), ctx.assets.count);
    try std.testing.expectEqual((try ctx.assets.get(first)).source.content_hash, (try ctx.assets.get(second)).source.content_hash);
    const first_identity = (try ctx.assets.get(first)).source.identity.?.file;
    const second_identity = (try ctx.assets.get(second)).source.identity.?.file;
    try std.testing.expect(first_identity.volume_serial != second_identity.volume_serial or first_identity.file_index != second_identity.file_index);
    try std.testing.expectEqual(first, try ctx.assets.open(&ctx, first_uri));
    try std.testing.expectEqual(@as(u32, 2), (try ctx.assets.get(first)).leases);
    try std.testing.expectEqual(@as(u32, 1), (try ctx.assets.get(second)).leases);
}

test "persistent external file authorization cannot become a directory snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const resource = try std.fs.path.join(allocator, &.{ root, "resources" });
    defer allocator.free(resource);
    const data = try std.fs.path.join(allocator, &.{ root, "data" });
    defer allocator.free(data);
    const path = try std.fs.path.join(allocator, &.{ root, "source.bin" });
    defer allocator.free(path);
    const retired = try std.fs.path.join(allocator, &.{ root, "retired.bin" });
    defer allocator.free(retired);
    try tmp.dir.createDir(io, "resources", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "source.bin", .data = "authorized file" });
    var ctx: RuntimeContext = undefined;
    try fixture(&ctx, root, resource, data);
    defer ctx.deinit();
    const id = try ctx.external_sources.import(&ctx, path);
    var uri_buffer: [64]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buffer, "external://{d}", .{id});
    try std.Io.Dir.renameAbsolute(path, retired, io);
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    const payload = "directory snapshot bytes";
    const digest = hex(hash(payload));
    const manifest = try std.fmt.allocPrint(allocator, "{{\"format\":\"cutrans-content-snapshot/1\",\"snapshot_id\":\"{s}\",\"content\":{{\"path\":\"content.bin\",\"byteLength\":{d},\"sha256\":\"{s}\"}},\"provenance\":{{\"source_kind\":\"pack\",\"source\":\"pack://assets/source.bin\"}}}}", .{ digest, payload.len, digest });
    defer allocator.free(manifest);
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "snapshot.json", .data = manifest });
    try dir.writeFile(io, .{ .sub_path = "content.bin", .data = payload });
    try std.testing.expectError(error.InvalidSourceFile, ctx.assets.open(&ctx, uri));
    try std.testing.expectEqual(@as(usize, 0), ctx.assets.count);
    const temporary_id = try ctx.mounts.grantExternal(allocator, path, .read_only);
    var temporary_buffer: [64]u8 = undefined;
    const temporary_uri = try std.fmt.bufPrint(&temporary_buffer, "external://{d}", .{temporary_id});
    var compatible = try readStandalone(&ctx, temporary_uri);
    defer compatible.deinit(allocator);
    try std.testing.expectEqual(SourceKind.snapshot, compatible.source.kind);
    try std.testing.expectEqualStrings(payload, compatible.bytes);
}

test "library Station versions coexist and bound reads do not implicitly retain browsed bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const resource = try std.fs.path.join(allocator, &.{ root, "resources" });
    defer allocator.free(resource);
    const data = try std.fs.path.join(allocator, &.{ root, "data" });
    defer allocator.free(data);
    const path = try std.fs.path.join(allocator, &.{ root, "source.png" });
    defer allocator.free(path);
    const replacement = try std.fs.path.join(allocator, &.{ root, "replacement.png" });
    defer allocator.free(replacement);
    const first_pixels = [_]u8{ 12, 34, 56, 255 };
    try image.savePngExternal(allocator, std.testing.io, path, .{ .width = 1, .height = 1, .pixels = @constCast(&first_pixels) });
    var ctx: RuntimeContext = undefined;
    try fixture(&ctx, root, resource, data);
    defer ctx.deinit();
    const library_id = try ctx.library.importExternal(&ctx, path);
    var uri_buffer: [64]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buffer, "library://{d}", .{library_id});
    const first = try ctx.assets.open(&ctx, uri);
    const first_hash = (try ctx.assets.get(first)).source.content_hash;
    {
        var browsed = try readVersion(&ctx, uri, first_hash);
        defer browsed.deinit(allocator);
        try std.testing.expectEqual(first_hash, browsed.source.content_hash);
    }
    const second_pixels = [_]u8{ 91, 82, 73, 255 };
    try image.savePngExternal(allocator, std.testing.io, replacement, .{ .width = 1, .height = 1, .pixels = @constCast(&second_pixels) });
    const changed_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, replacement, allocator, .limited(1024 * 1024));
    defer allocator.free(changed_bytes);
    // Keep the external file identity while explicitly changing its contents.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = changed_bytes });
    try std.testing.expect(try ctx.library.refresh(&ctx, library_id));
    const second = try ctx.assets.open(&ctx, uri);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(usize, 2), ctx.assets.count);
    try std.testing.expectEqual(first_hash, (try ctx.assets.get(first)).source.content_hash);
    try std.testing.expect(!std.mem.eql(u8, &first_hash, &(try ctx.assets.get(second)).source.content_hash));
    try std.testing.expectError(error.ResourceVersionUnavailable, readVersion(&ctx, uri, first_hash));
    const old_asset = try ctx.assets.get(first);
    try ctx.library.retainVersion(&ctx, library_id, old_asset.source.content_hash, old_asset.bytes);
    const pinned = try ctx.assets.openVersion(&ctx, uri, first_hash);
    try std.testing.expectEqual(first, pinned);
    try std.testing.expectEqual(@as(u32, 2), (try ctx.assets.get(first)).leases);
    const first_index = ctx.assets.find(first).?;
    ctx.assets.items[first_index].leases = std.math.maxInt(u32);
    const revision = ctx.assets.revision;
    try std.testing.expectError(error.AssetLeaseLimit, ctx.assets.openVersion(&ctx, uri, first_hash));
    try std.testing.expectEqual(std.math.maxInt(u32), (try ctx.assets.get(first)).leases);
    try std.testing.expectEqual(revision, ctx.assets.revision);
    try std.testing.expectEqual(@as(usize, 2), ctx.assets.count);
    ctx.assets.items[first_index].leases = 2;
    try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
    var retained = try readVersion(&ctx, uri, first_hash);
    defer retained.deinit(allocator);
    var decoded = try image.decode(allocator, retained.bytes);
    defer decoded.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &first_pixels, decoded.pixels);
    const relative = try @import("resource_versions.zig").relativePath(allocator, library_id, first_hash);
    defer allocator.free(relative);
    var data_dir = try ctx.paths.openDataDir(std.testing.io, allocator);
    defer data_dir.close(std.testing.io);
    try data_dir.writeFile(std.testing.io, .{ .sub_path = relative, .data = "corrupt retained Source" });
    const before_corrupt_read = ctx.assets.revision;
    try std.testing.expectError(error.ResourceVersionContentMismatch, ctx.assets.openVersion(&ctx, uri, first_hash));
    try std.testing.expectEqual(@as(u32, 2), (try ctx.assets.get(first)).leases);
    try std.testing.expectEqual(before_corrupt_read, ctx.assets.revision);
    try ctx.assets.release(first);
    try ctx.assets.release(pinned);
    try ctx.assets.release(second);
    try std.testing.expectEqual(@as(usize, 0), ctx.assets.count);
}

const ResidentCase = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    resource: []u8,
    data: []u8,
    source: []u8,

    fn init() !ResidentCase {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        errdefer allocator.free(root);
        const resource = try std.fs.path.join(allocator, &.{ root, "resources" });
        errdefer allocator.free(resource);
        const data = try std.fs.path.join(allocator, &.{ root, "data" });
        errdefer allocator.free(data);
        const source = try std.fs.path.join(allocator, &.{ root, "source.bin" });
        errdefer allocator.free(source);
        try tmp.dir.createDir(std.testing.io, "resources", .default_dir);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.bin", .data = "resident source A" });
        return .{ .tmp = tmp, .root = root, .resource = resource, .data = data, .source = source };
    }

    fn deinit(self: *ResidentCase) void {
        for ([_][]u8{ self.source, self.data, self.resource }) |path| std.testing.allocator.free(path);
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn open(self: *const ResidentCase, ctx: *RuntimeContext) !void {
        try fixture(ctx, self.root, self.resource, self.data);
    }

    fn dataBytes(self: *const ResidentCase, relative: []const u8) ![]u8 {
        const allocator = std.testing.allocator;
        const path = try std.fs.path.join(allocator, &.{ self.data, relative });
        defer allocator.free(path);
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    }
};

test "resource ensure is RAM only bounded and never merges resource identities" {
    var tc = try ResidentCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const bytes = "two resources may own identical bytes";
    const first = try ctx.library.create(&ctx, "first.bin", bytes);
    const second = try ctx.library.create(&ctx, "second.bin", bytes);
    const digest = hash(bytes);
    const first_handle = try ctx.assets.ensureResource(&ctx, first, digest);
    const second_handle = try ctx.assets.ensureResource(&ctx, second, digest);
    try std.testing.expect(first_handle != second_handle);
    try std.testing.expectEqual(@as(usize, 2), ctx.assets.count);
    const revision = ctx.assets.revision;
    const next_handle = ctx.assets.next_handle;
    const total_bytes = ctx.assets.total_bytes;
    ctx.io = null;
    for (0..128) |_| {
        try std.testing.expectEqual(first_handle, try ctx.assets.ensureResource(&ctx, first, digest));
        try std.testing.expectEqual(second_handle, try ctx.assets.ensureResource(&ctx, second, digest));
    }
    var different = digest;
    different[0] ^= 1;
    try std.testing.expectError(error.SourceContentMismatch, ctx.assets.ensureResource(&ctx, first, different));
    try std.testing.expectError(error.ResourceNotFound, ctx.assets.ensureResource(&ctx, 999, digest));
    try std.testing.expectEqual(revision, ctx.assets.revision);
    try std.testing.expectEqual(next_handle, ctx.assets.next_handle);
    try std.testing.expectEqual(total_bytes, ctx.assets.total_bytes);
    try std.testing.expectEqual(@as(u32, 1), (try ctx.assets.get(first_handle)).leases);
    try std.testing.expectEqual(@as(u32, 1), (try ctx.assets.get(second_handle)).leases);
    try std.testing.expectEqual(first_handle, ctx.assets.findResourceHead(first, digest).?.handle);
    try std.testing.expect(ctx.assets.findResourceHead(first, different) == null);
    try ctx.assets.release(first_handle);
    try std.testing.expectEqual(@as(usize, 1), ctx.assets.count);
    try std.testing.expectError(error.IoNotReady, ctx.assets.ensureResource(&ctx, first, digest));
}

test "resource ensure never substitutes a resident old head and check supersedes without IO" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tc = try ResidentCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const id = try ctx.library.importExternal(&ctx, tc.source);
    const old_hash = ctx.library.get(id).?.content_hash;
    const old_handle = try ctx.assets.ensureResource(&ctx, id, old_hash);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tc.source, .data = "resident source B" });
    try std.testing.expect(try ctx.library.refresh(&ctx, id));
    const new_hash = ctx.library.get(id).?.content_hash;
    try std.testing.expectError(error.SourceContentMismatch, ctx.assets.ensureResource(&ctx, id, old_hash));
    const new_handle = try ctx.assets.ensureResource(&ctx, id, new_hash);
    try std.testing.expect(old_handle != new_handle);
    try std.testing.expectEqualStrings("resident source A", (try ctx.assets.get(old_handle)).bytes);
    try std.testing.expectEqualStrings("resident source B", (try ctx.assets.get(new_handle)).bytes);
    const catalog_revision = ctx.library.revision;
    ctx.io = null;
    try ctx.assets.checkResource(&ctx, old_handle);
    try std.testing.expectEqual(vne.assets.SourceStatus.superseded, (try ctx.assets.get(old_handle)).source_status);
    try std.testing.expectEqual(vne.assets.SourceStatus.superseded, Workspace.visibleSourceStatus(&ctx, try ctx.assets.get(old_handle)));
    const observed_revision = ctx.assets.revision;
    try ctx.assets.checkResource(&ctx, old_handle);
    try std.testing.expectEqual(observed_revision, ctx.assets.revision);
    try std.testing.expectEqual(catalog_revision, ctx.library.revision);
    try std.testing.expectEqual(@as(u32, 1), (try ctx.assets.get(old_handle)).leases);
    try std.testing.expectEqual(new_handle, try ctx.assets.ensureResource(&ctx, id, new_hash));
}

test "loaded source checks preserve bytes catalog authorization and document while reporting drift" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tc = try ResidentCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const allocator = std.testing.allocator;
    const id = try ctx.library.importExternal(&ctx, tc.source);
    const digest = ctx.library.get(id).?.content_hash;
    const handle = try ctx.assets.ensureResource(&ctx, id, digest);
    const catalog = try tc.dataBytes(@import("resource_library.zig").catalog_path);
    defer allocator.free(catalog);
    const authorization = try tc.dataBytes(@import("external_sources.zig").catalog_path);
    defer allocator.free(authorization);
    const catalog_revision = ctx.library.revision;
    const document_fingerprint = ctx.document.fingerprint();
    try ctx.assets.checkResource(&ctx, handle);
    try std.testing.expectEqual(vne.assets.SourceStatus.unchanged, (try ctx.assets.get(handle)).source_status);
    const checked_revision = ctx.assets.revision;
    try ctx.assets.checkResource(&ctx, handle);
    try std.testing.expectEqual(checked_revision, ctx.assets.revision);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tc.source, .data = "changed bytes with the same file identity" });
    try ctx.assets.checkResource(&ctx, handle);
    try std.testing.expectEqual(vne.assets.SourceStatus.content_changed, (try ctx.assets.get(handle)).source_status);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, tc.source);
    try ctx.assets.checkResource(&ctx, handle);
    try std.testing.expectEqual(vne.assets.SourceStatus.missing, (try ctx.assets.get(handle)).source_status);
    try std.testing.expectEqual(handle, try ctx.assets.ensureResource(&ctx, id, digest));
    try std.testing.expectEqualStrings("resident source A", (try ctx.assets.get(handle)).bytes);
    try std.testing.expectEqual(@as(u32, 1), (try ctx.assets.get(handle)).leases);
    try std.testing.expectEqual(catalog_revision, ctx.library.revision);
    try std.testing.expectEqual(document_fingerprint, ctx.document.fingerprint());
    const current_catalog = try tc.dataBytes(@import("resource_library.zig").catalog_path);
    defer allocator.free(current_catalog);
    const current_authorization = try tc.dataBytes(@import("external_sources.zig").catalog_path);
    defer allocator.free(current_authorization);
    try std.testing.expectEqualSlices(u8, catalog, current_catalog);
    try std.testing.expectEqualSlices(u8, authorization, current_authorization);
}

test "source observation belongs to binding not logical name and detach invalidates it" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tc = try ResidentCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const id = try ctx.library.importExternal(&ctx, tc.source);
    const handle = try ctx.assets.ensureResource(&ctx, id, ctx.library.get(id).?.content_hash);
    try ctx.assets.checkResource(&ctx, handle);
    try ctx.library.rename(&ctx, id, "renamed source");
    const folder = try ctx.library.createFolder(&ctx, 0, "folder");
    try ctx.library.move(&ctx, id, folder);
    try std.testing.expectEqual(vne.assets.SourceStatus.unchanged, Workspace.visibleSourceStatus(&ctx, try ctx.assets.get(handle)));
    try ctx.library.detach(&ctx, id);
    try std.testing.expectEqual(vne.assets.SourceStatus.unchanged, (try ctx.assets.get(handle)).source_status);
    try std.testing.expectEqual(vne.assets.SourceStatus.unchecked, Workspace.visibleSourceStatus(&ctx, try ctx.assets.get(handle)));
    const before_check = ctx.assets.revision;
    try ctx.assets.checkResource(&ctx, handle);
    try std.testing.expectEqual(before_check + 1, ctx.assets.revision);
    try std.testing.expectEqual(vne.assets.SourceStatus.unchanged, Workspace.visibleSourceStatus(&ctx, try ctx.assets.get(handle)));
    const resource = &ctx.library.items[0];
    const old_source = resource.source_uri;
    const alternative = try std.testing.allocator.dupe(u8, "external://999");
    resource.source_uri = alternative;
    defer {
        resource.source_uri = old_source;
        std.testing.allocator.free(alternative);
    }
    ctx.io = null;
    try std.testing.expectEqual(vne.assets.SourceStatus.unchecked, Workspace.visibleSourceStatus(&ctx, try ctx.assets.get(handle)));
}

test "checks reject unowned targets reserve revision before IO and never classify unavailable as missing" {
    var tc = try ResidentCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const id = try ctx.library.create(&ctx, "owned.bin", "owned bytes");
    const handle = try ctx.assets.ensureResource(&ctx, id, ctx.library.get(id).?.content_hash);
    try std.testing.expectError(error.AssetNotFound, ctx.assets.checkResource(&ctx, 999));
    const index = ctx.assets.find(handle).?;
    ctx.assets.items[index].source.kind = .pack;
    try std.testing.expectError(error.InvalidResourceState, ctx.assets.checkResource(&ctx, handle));
    ctx.assets.items[index].source.kind = .library;
    const revision = ctx.assets.revision;
    ctx.assets.revision = std.math.maxInt(u64);
    ctx.io = null;
    try std.testing.expectError(error.AssetRevisionExhausted, ctx.assets.checkResource(&ctx, handle));
    try std.testing.expectEqual(vne.assets.SourceStatus.unchecked, (try ctx.assets.get(handle)).source_status);
    ctx.assets.revision = revision;
    try ctx.assets.checkResource(&ctx, handle);
    try std.testing.expectEqual(vne.assets.SourceStatus.unavailable, (try ctx.assets.get(handle)).source_status);
    try std.testing.expectEqual(vne.assets.SourceStatus.unavailable, sourceErrorStatus(error.SourceBusy));
    try std.testing.expectEqual(vne.assets.SourceStatus.identity_changed, sourceErrorStatus(error.SourceIdentityChanged));
    try std.testing.expectEqual(vne.assets.SourceStatus.unverified, sourceErrorStatus(error.LegacyExternalIdentityUnverified));
    try std.testing.expectEqual(vne.assets.SourceStatus.content_changed, sourceErrorStatus(error.ResourceVersionContentMismatch));
    try std.testing.expectEqualStrings("owned bytes", (try ctx.assets.get(handle)).bytes);
}

test "ensure and check commands validate exact tuples without publishing tasks" {
    var tc = try ResidentCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const id = try ctx.library.create(&ctx, "owned.bin", "owned bytes");
    var buffer: [96]u8 = undefined;
    const digest = hex(ctx.library.get(id).?.content_hash);
    const argument = try std.fmt.bufPrint(&buffer, "{d} {s}", .{ id, &digest });
    const first = dispatch(.{ .name = "asset.ensure", .arg = argument }, &ctx);
    try std.testing.expectEqual(command.Code.accepted, first.code);
    try std.testing.expect(first.task_id == null);
    const revision = ctx.assets.revision;
    try std.testing.expectEqual(command.Code.accepted, dispatch(.{ .name = "asset.ensure", .arg = argument }, &ctx).code);
    try std.testing.expectEqual(revision, ctx.assets.revision);
    for ([_]?[]const u8{ null, "", "0", "1 xyz", "1 00", "1 0000000000000000000000000000000000000000000000000000000000000000 extra" }) |invalid| {
        try std.testing.expectEqual(command.Code.invalid_arguments, dispatch(.{ .name = "asset.ensure", .arg = invalid }, &ctx).code);
    }
    try std.testing.expectEqual(command.Code.invalid_state, dispatch(.{ .name = "asset.check", .arg = "999" }, &ctx).code);
}

test "generic resource acquisition preserves unknown bytes and decode failure never unregisters them" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tc = try ResidentCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const allocator = std.testing.allocator;
    const payload = "\x00\xffunknown file\x00";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tc.source, .data = payload });
    const id = try ctx.library.registerFile(&ctx, tc.source);
    const digest = ctx.library.get(id).?.content_hash;
    const handle = try ctx.assets.ensureFile(&ctx, id, digest);
    try std.testing.expectEqualSlices(u8, payload, (try ctx.assets.get(handle)).bytes);
    const catalog_revision = ctx.library.revision;
    const assets_revision = ctx.assets.revision;
    if (ctx.assets.preview(handle)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expectEqualSlices(u8, payload, (try ctx.assets.get(handle)).bytes);
    try std.testing.expectEqual(@as(u32, 1), (try ctx.assets.get(handle)).leases);
    try std.testing.expectEqual(catalog_revision, ctx.library.revision);
    try std.testing.expectEqual(assets_revision, ctx.assets.revision);
    const auth_path = try ctx.paths.dataPath(allocator, @import("external_sources.zig").catalog_path);
    defer allocator.free(auth_path);
    const auth_before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, auth_path, allocator, .limited(256 * 1024));
    defer allocator.free(auth_before);
    // Drop the root lease so the next acquire exercises the pure Source read,
    // rather than succeeding through a resident cache hit.
    try ctx.assets.release(handle);
    const new_handle = try ctx.assets.ensureFile(&ctx, id, digest);
    try std.testing.expect(new_handle != handle);
    const auth_after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, auth_path, allocator, .limited(256 * 1024));
    defer allocator.free(auth_after);
    try std.testing.expectEqualSlices(u8, auth_before, auth_after);
    const revision = ctx.assets.revision;
    ctx.io = null;
    for (0..16) |_| try std.testing.expectEqual(new_handle, try ctx.assets.ensureFile(&ctx, id, digest));
    try std.testing.expectEqual(revision, ctx.assets.revision);
    try std.testing.expectEqual(@as(u32, 1), (try ctx.assets.get(new_handle)).leases);
}

test "generic text can be detached from full RAM and recovered cold without the source" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tc = try ResidentCase.init();
    defer tc.deinit();
    const allocator = std.testing.allocator;
    const text_path = try std.fs.path.join(allocator, &.{ tc.root, "note.txt" });
    defer allocator.free(text_path);
    const text = "a complete text file / 正文\n";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = text_path, .data = text });
    var id: u64 = undefined;
    var digest: [32]u8 = undefined;
    {
        var ctx: RuntimeContext = undefined;
        try tc.open(&ctx);
        defer ctx.deinit();
        id = try ctx.library.registerFile(&ctx, text_path);
        digest = ctx.library.get(id).?.content_hash;
        const folder = try ctx.library.createFolder(&ctx, 0, "notes");
        try ctx.library.move(&ctx, id, folder);
        const handle = try ctx.assets.ensureFile(&ctx, id, digest);
        try std.Io.Dir.cwd().deleteFile(std.testing.io, text_path);
        try std.testing.expectEqual(handle, try ctx.assets.ensureFile(&ctx, id, digest));
        try ctx.library.detach(&ctx, id);
        try std.testing.expectEqualStrings("note.txt", ctx.library.get(id).?.label);
        try std.testing.expectEqual(folder, ctx.library.get(id).?.parent_id);
        try std.testing.expectEqual(@import("resource_library.zig").Kind.owned, ctx.library.get(id).?.kind);
    }
    var restored: RuntimeContext = undefined;
    try tc.open(&restored);
    defer restored.deinit();
    try restored.external_sources.restore(&restored);
    try restored.library.restore(&restored);
    const handle = try restored.assets.ensureFile(&restored, id, digest);
    try std.testing.expectEqualSlices(u8, text, (try restored.assets.get(handle)).bytes);
    try std.testing.expectEqualStrings("note.txt", restored.library.get(id).?.label);
    try std.testing.expectEqual(@import("resource_library.zig").Kind.owned, restored.library.get(id).?.kind);
}

test "generic acquire command accepts a registered file without manufacturing a task or decoding PNG" {
    var tc = try ResidentCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const id = try ctx.library.create(&ctx, "unknown.bin", "opaque bytes");
    const digest = ctx.library.get(id).?.content_hash;
    var buffer: [96]u8 = undefined;
    const argument = try std.fmt.bufPrint(&buffer, "{d} {s}", .{ id, hex(digest) });
    const result = dispatch(.{ .name = "resource.acquire", .arg = argument }, &ctx);
    try std.testing.expectEqual(command.Code.accepted, result.code);
    try std.testing.expect(result.task_id == null);
    const revision = ctx.assets.revision;
    const handle = ctx.assets.findResourceHead(id, digest).?.handle;
    try std.testing.expectEqual(command.Code.accepted, dispatch(.{ .name = "resource.acquire", .arg = argument }, &ctx).code);
    try std.testing.expectEqual(revision, ctx.assets.revision);
    try std.testing.expectEqual(@as(u32, 1), (try ctx.assets.get(handle)).leases);
    try std.testing.expectEqual(command.Code.invalid_arguments, dispatch(.{ .name = "resource.acquire", .arg = "1 not-a-hash" }, &ctx).code);
}
