//! 可恢复的外部 Source 授权;宿主路径只住在用户 Session,不进入 .cut/Pack/快照。

const std = @import("std");
const RuntimeContext = @import("context.zig").Context;
const storage = @import("storage.zig");
const command = @import("command.zig");
const file_identity = @import("ports").file_identity;
const source_boundary = @import("source_boundary.zig");

pub const catalog_path = "session/external-sources.json";
pub const verified_identity_scheme = "win32-file-id/1";
pub const legacy_identity_scheme = "legacy-cutrans-layout/1";
const max_path = 4096;
const max_source_bytes = 16 * 1024 * 1024;
const max_catalog_bytes = 256 * 1024;

const IdentityScheme = enum {
    legacy,
    verified,

    fn text(self: IdentityScheme) []const u8 {
        return switch (self) {
            .legacy => legacy_identity_scheme,
            .verified => verified_identity_scheme,
        };
    }
};

const Record = struct {
    id: u64,
    path: []u8,
    identity_scheme: IdentityScheme,
    identity: ?file_identity.Identity,
    last_hash: ?[32]u8 = null,
};

const Manifest = struct {
    format: []const u8,
    sources: []Entry,
};

const Entry = struct {
    id: u64,
    path: []const u8,
    access: []const u8,
    identity_scheme: ?[]const u8 = null,
    volume_serial: ?u32 = null,
    file_index: ?u64 = null,
    last_sha256: ?[]const u8 = null,
};

fn identityEqual(left: ?file_identity.Identity, right: ?file_identity.Identity) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.volume_serial == right.?.volume_serial and left.?.file_index == right.?.file_index;
}

fn verifyIdentity(record: *const Record, current: ?file_identity.Identity) !void {
    if (record.identity_scheme == .legacy) return error.LegacyExternalIdentityUnverified;
    if (record.identity == null or current == null or !identityEqual(record.identity, current)) return error.SourceIdentityChanged;
}

fn pathEqual(left: []const u8, right: []const u8) bool {
    return if (@import("builtin").os.tag == .windows) std.ascii.eqlIgnoreCase(left, right) else std.mem.eql(u8, left, right);
}

fn validPath(path: []const u8) bool {
    return path.len > 0 and path.len <= max_path and std.fs.path.isAbsolute(path) and std.mem.indexOfScalar(u8, path, 0) == null;
}

pub const Frozen = struct {
    path: []u8,
    bytes: []u8,
    identity: file_identity.Identity,
    digest: [32]u8,

    pub fn deinit(self: *Frozen, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// An explicit candidate read is independent of existing grants and does not
/// authorize, observe, adopt or retain anything. The caller owns all bytes.
pub fn readFrozen(ctx: *RuntimeContext, path: []const u8) !Frozen {
    const io = ctx.io orelse return error.IoNotReady;
    if (!validPath(path)) return error.InvalidExternalPath;
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, ctx.allocator);
    defer ctx.allocator.free(canonical);
    if (!validPath(canonical)) return error.InvalidExternalPath;
    var read = try file_identity.readStable(ctx.allocator, io, canonical, max_source_bytes);
    errdefer read.deinit(ctx.allocator);
    const identity = read.identity orelse return error.FileIdentityUnavailable;
    const owned_path = try ctx.allocator.dupe(u8, canonical);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(read.bytes, &digest, .{});
    return .{ .path = owned_path, .bytes = read.bytes, .identity = identity, .digest = digest };
}

/// New ordinary files use a stricter admission boundary than legacy PNG grants.
/// Final path, identity and bytes describe one opened read-only file object.
pub fn readFileSnapshot(ctx: *RuntimeContext, path: []const u8) !Frozen {
    const io = ctx.io orelse return error.IoNotReady;
    if (!validPath(path)) return error.InvalidExternalPath;
    const Policy = struct {
        ctx: *RuntimeContext,
        input: []const u8,

        fn check(pointer: *anyopaque, final: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            if (!validPath(final)) return error.InvalidExternalPath;
            try source_boundary.check(self.ctx.allocator, self.ctx.io.?, self.input, final, self.ctx.paths.data_dir, self.ctx.paths.resource_dir);
        }
    };
    var policy = Policy{ .ctx = ctx, .input = path };
    var read = try file_identity.readStablePath(ctx.allocator, io, path, max_source_bytes, .{ .context = &policy, .check = Policy.check });
    errdefer read.deinit(ctx.allocator);
    if (!validPath(read.path)) return error.InvalidExternalPath;
    const identity = read.identity orelse return error.FileIdentityUnavailable;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(read.bytes, &digest, .{});
    return .{ .path = read.path, .bytes = read.bytes, .identity = identity, .digest = digest };
}

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

pub const Catalog = struct {
    items: [8]Record = undefined,
    count: usize = 0,

    pub fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        for (self.items[0..self.count]) |record| allocator.free(record.path);
        self.* = .{};
    }

    fn findPath(self: *Catalog, path: []const u8) ?*Record {
        for (self.items[0..self.count]) |*record| {
            if (pathEqual(record.path, path)) return record;
        }
        return null;
    }

    fn findId(self: *Catalog, id: u64) ?*Record {
        for (self.items[0..self.count]) |*record| {
            if (record.id == id) return record;
        }
        return null;
    }

    fn hasVerifiedPath(self: *const Catalog, path: []const u8) bool {
        for (self.items[0..self.count]) |record| {
            if (record.identity_scheme == .verified and pathEqual(record.path, path)) return true;
        }
        return false;
    }

    pub fn findFile(self: *const Catalog, frozen: *const Frozen) ?u64 {
        for (self.items[0..self.count]) |record| {
            if (record.identity_scheme == .verified and pathEqual(record.path, frozen.path) and identityEqual(record.identity, frozen.identity)) return record.id;
        }
        return null;
    }

    /// Borrow one new-policy snapshot; never reopen its bytes or update the
    /// observation hash of an existing grant. A failed library publication can
    /// leave this explicitly authorized dependency without an adopted entry.
    pub fn importFile(self: *Catalog, ctx: *RuntimeContext, frozen: *const Frozen) !u64 {
        if (self.findFile(frozen)) |id| {
            const uri = @import("vne").uri.Uri{ .root = .external, .body = try std.fmt.allocPrint(ctx.allocator, "{d}", .{id}) };
            defer ctx.allocator.free(uri.body);
            if (!(try ctx.mounts.isPersistentExternal(uri))) return error.ExternalGrantNotFound;
            const resolved = try ctx.mounts.resolveAlloc(ctx.allocator, uri);
            defer ctx.allocator.free(resolved.path);
            if (resolved.access != .read_only) return error.ReadOnlySourceRequired;
            if (!pathEqual(resolved.path, frozen.path)) return error.InvalidExternalGrant;
            return self.publishFrozen(ctx, frozen);
        }
        const io = ctx.io orelse return error.IoNotReady;
        try source_boundary.check(ctx.allocator, io, frozen.path, frozen.path, ctx.paths.data_dir, ctx.paths.resource_dir);
        return self.publishFrozen(ctx, frozen);
    }

    /// Only submit-time, proof-checked Frozen values may cross this boundary.
    /// Existing grants never change identity or locator. A later library save
    /// may fail, leaving this explicit authorization as an unused dependency.
    pub fn publishFrozen(self: *Catalog, ctx: *RuntimeContext, frozen: *const Frozen) !u64 {
        if (!validPath(frozen.path) or frozen.bytes.len > max_source_bytes) return error.InvalidExternalPath;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(frozen.bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &frozen.digest)) return error.SourceContentMismatch;
        for (self.items[0..self.count]) |record| {
            if (record.identity_scheme == .verified and pathEqual(record.path, frozen.path) and identityEqual(record.identity, frozen.identity)) return record.id;
        }
        if (self.count == self.items.len) return error.ExternalGrantTableFull;
        if (ctx.mounts.next_grant_id == 0) return error.ExternalGrantIdExhausted;
        const path = try ctx.allocator.dupe(u8, frozen.path);
        errdefer ctx.allocator.free(path);
        const id = try ctx.mounts.grantPersistentExternal(ctx.allocator, frozen.path, .read_only, null);
        errdefer _ = ctx.mounts.revokeExternal(ctx.allocator, id);
        self.items[self.count] = .{ .id = id, .path = path, .identity_scheme = .verified, .identity = frozen.identity, .last_hash = digest };
        self.count += 1;
        errdefer self.count -= 1;
        try self.save(ctx);
        return id;
    }

    fn save(self: *const Catalog, ctx: *RuntimeContext) !void {
        const io = ctx.io orelse return error.IoNotReady;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ctx.allocator);
        try out.appendSlice(ctx.allocator, "{\"format\":\"cutrans-external-sources/2\",\"sources\":[");
        for (self.items[0..self.count], 0..) |record, index| {
            if (index != 0) try out.appendSlice(ctx.allocator, ",");
            try appendFmt(&out, ctx.allocator, "{{\"id\":{d},\"path\":{f},\"access\":\"read_only\",\"identity_scheme\":{f},\"volume_serial\":", .{ record.id, std.json.fmt(record.path, .{}), std.json.fmt(record.identity_scheme.text(), .{}) });
            if (record.identity) |identity| {
                try appendFmt(&out, ctx.allocator, "{d},\"file_index\":{d},\"last_sha256\":", .{ identity.volume_serial, identity.file_index });
            } else {
                try out.appendSlice(ctx.allocator, "null,\"file_index\":null,\"last_sha256\":");
            }
            if (record.last_hash) |digest| {
                const hex = std.fmt.bytesToHex(digest, .lower);
                try appendFmt(&out, ctx.allocator, "{f}", .{std.json.fmt(&hex, .{})});
            } else {
                try out.appendSlice(ctx.allocator, "null");
            }
            try out.appendSlice(ctx.allocator, "}");
        }
        try out.appendSlice(ctx.allocator, "]}\n");
        const path = try ctx.paths.dataPath(ctx.allocator, catalog_path);
        defer ctx.allocator.free(path);
        try storage.writeAtomic(std.Io.Dir.cwd(), io, path, out.items);
    }

    pub fn import(self: *Catalog, ctx: *RuntimeContext, path: []const u8) !u64 {
        const io = ctx.io orelse return error.IoNotReady;
        if (!validPath(path)) return error.InvalidExternalPath;
        // A known legacy grant is evidence only. Do not probe its file as a
        // side effect of import, nor silently turn it into a new authorization.
        if (self.findPath(path)) |record| {
            if (record.identity_scheme == .legacy and !self.hasVerifiedPath(path)) return error.LegacyExternalIdentityUnverified;
        }
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, ctx.allocator);
        defer ctx.allocator.free(canonical);
        if (!validPath(canonical)) return error.InvalidExternalPath;
        if (self.findPath(canonical)) |record| {
            if (record.identity_scheme == .legacy and !self.hasVerifiedPath(canonical)) return error.LegacyExternalIdentityUnverified;
            var read = try file_identity.readStable(ctx.allocator, io, canonical, max_source_bytes);
            defer read.deinit(ctx.allocator);
            for (self.items[0..self.count]) |candidate| {
                if (candidate.identity_scheme == .verified and pathEqual(candidate.path, canonical) and identityEqual(candidate.identity, read.identity)) return candidate.id;
            }
            return error.SourceIdentityChanged;
        }
        if (self.count == self.items.len) return error.ExternalGrantTableFull;
        if (ctx.mounts.next_grant_id == 0) return error.ExternalGrantIdExhausted;
        var read = try file_identity.readStable(ctx.allocator, io, canonical, max_source_bytes);
        defer read.deinit(ctx.allocator);
        const current = read.identity orelse return error.FileIdentityUnavailable;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(read.bytes, &digest, .{});
        const id = try ctx.mounts.grantPersistentExternal(ctx.allocator, canonical, .read_only, null);
        errdefer _ = ctx.mounts.revokeExternal(ctx.allocator, id);
        self.items[self.count] = .{
            .id = id,
            .path = try ctx.allocator.dupe(u8, canonical),
            .identity_scheme = .verified,
            .identity = current,
            .last_hash = digest,
        };
        self.count += 1;
        errdefer {
            ctx.allocator.free(self.items[self.count - 1].path);
            self.count -= 1;
        }
        try self.save(ctx);
        return id;
    }

    /// Catalogued grants authorize a file, never an external snapshot folder.
    pub fn hasRecord(self: *Catalog, uri: @import("vne").uri.Uri) !bool {
        if (uri.root != .external) return false;
        const id = std.fmt.parseInt(u64, uri.body, 10) catch return error.InvalidExternalGrant;
        return self.findId(id) != null;
    }

    pub fn requireVerified(self: *Catalog, uri: @import("vne").uri.Uri) !void {
        if (uri.root != .external) return;
        const id = std.fmt.parseInt(u64, uri.body, 10) catch return error.InvalidExternalGrant;
        const record = self.findId(id) orelse return;
        if (record.identity_scheme == .legacy) return error.LegacyExternalIdentityUnverified;
    }

    /// Observe an already authorized file without publishing observation hashes,
    /// refreshing a library head, or acquiring a Station lease.
    pub fn observe(self: *Catalog, ctx: *RuntimeContext, source_uri: []const u8) !Frozen {
        const uri = @import("vne").uri.parse(source_uri) catch return error.InvalidExternalGrant;
        if (uri.root != .external) return error.InvalidExternalGrant;
        for (uri.body) |byte| if (byte < '0' or byte > '9') return error.InvalidExternalGrant;
        const id = std.fmt.parseInt(u64, uri.body, 10) catch return error.InvalidExternalGrant;
        if (id == 0) return error.InvalidExternalGrant;
        const record = self.findId(id) orelse return error.ExternalSourceNotFound;
        if (record.identity_scheme == .legacy) return error.LegacyExternalIdentityUnverified;
        if (!(try ctx.mounts.isPersistentExternal(uri))) return error.ExternalGrantNotFound;
        const resolved = try ctx.mounts.resolveAlloc(ctx.allocator, uri);
        defer ctx.allocator.free(resolved.path);
        if (!pathEqual(record.path, resolved.path)) return error.InvalidExternalGrant;
        var frozen = try readFrozen(ctx, record.path);
        errdefer frozen.deinit(ctx.allocator);
        try verifyIdentity(record, frozen.identity);
        return frozen;
    }

    pub fn observeFile(self: *Catalog, ctx: *RuntimeContext, source_uri: []const u8) !Frozen {
        const uri = @import("vne").uri.parse(source_uri) catch return error.InvalidExternalGrant;
        if (uri.root != .external) return error.InvalidExternalGrant;
        for (uri.body) |byte| if (byte < '0' or byte > '9') return error.InvalidExternalGrant;
        const id = std.fmt.parseInt(u64, uri.body, 10) catch return error.InvalidExternalGrant;
        if (id == 0) return error.InvalidExternalGrant;
        const record = self.findId(id) orelse return error.ExternalSourceNotFound;
        if (record.identity_scheme == .legacy) return error.LegacyExternalIdentityUnverified;
        if (!(try ctx.mounts.isPersistentExternal(uri))) return error.ExternalGrantNotFound;
        const resolved = try ctx.mounts.resolveAlloc(ctx.allocator, uri);
        defer ctx.allocator.free(resolved.path);
        if (resolved.access != .read_only) return error.ReadOnlySourceRequired;
        if (!pathEqual(record.path, resolved.path)) return error.InvalidExternalGrant;
        var frozen = try readFileSnapshot(ctx, record.path);
        errdefer frozen.deinit(ctx.allocator);
        try verifyIdentity(record, frozen.identity);
        return frozen;
    }

    pub fn confirmLegacy(self: *Catalog, ctx: *RuntimeContext, id: u64, expected_digest: [32]u8, path: []const u8) !void {
        const io = ctx.io orelse return error.IoNotReady;
        const record = self.findId(id) orelse return error.ExternalSourceNotFound;
        if (!validPath(path)) return error.InvalidExternalPath;
        // Resolve only the explicitly supplied confirmation target. The stored
        // locator and grant are never changed, even if that path was replaced.
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, ctx.allocator);
        defer ctx.allocator.free(canonical);
        if (!pathEqual(record.path, canonical)) return error.ExternalConfirmationPathMismatch;
        var read = try file_identity.readStable(ctx.allocator, io, canonical, max_source_bytes);
        defer read.deinit(ctx.allocator);
        const current = read.identity orelse return error.FileIdentityUnavailable;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(read.bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &expected_digest)) return error.SourceContentMismatch;
        if (record.identity_scheme == .verified) {
            try verifyIdentity(record, current);
            return;
        }
        const previous = record.*;
        record.identity_scheme = .verified;
        record.identity = current;
        record.last_hash = digest;
        self.save(ctx) catch |err| {
            record.* = previous;
            return err;
        };
    }

    pub fn noteRead(self: *Catalog, ctx: *RuntimeContext, uri: @import("vne").uri.Uri, current: ?file_identity.Identity, content_hash: [32]u8) !void {
        if (uri.root != .external) return;
        const id = std.fmt.parseInt(u64, uri.body, 10) catch return error.InvalidExternalGrant;
        const record = self.findId(id) orelse return;
        try verifyIdentity(record, current);
        if (identityEqual(record.identity, current) and record.last_hash != null and std.mem.eql(u8, &record.last_hash.?, &content_hash)) return;
        const previous_hash = record.last_hash;
        record.last_hash = content_hash;
        self.save(ctx) catch |err| {
            record.last_hash = previous_hash;
            return err;
        };
    }

    pub fn restore(self: *Catalog, ctx: *RuntimeContext) !void {
        const io = ctx.io orelse return error.IoNotReady;
        const path = try ctx.paths.dataPath(ctx.allocator, catalog_path);
        defer ctx.allocator.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, ctx.allocator, .limited(max_catalog_bytes)) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer ctx.allocator.free(text);
        const parsed = std.json.parseFromSlice(Manifest, ctx.allocator, text, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch return error.InvalidExternalSourceCatalog;
        defer parsed.deinit();
        const manifest = parsed.value;
        const legacy = std.mem.eql(u8, manifest.format, "cutrans-external-sources/1");
        if ((!legacy and !std.mem.eql(u8, manifest.format, "cutrans-external-sources/2")) or manifest.sources.len > self.items.len) return error.InvalidExternalSourceCatalog;
        var next: Catalog = .{};
        errdefer next.deinit(ctx.allocator);
        for (manifest.sources) |entry| {
            if (entry.id == 0 or !validPath(entry.path) or !std.mem.eql(u8, entry.access, "read_only")) return error.InvalidExternalSourceCatalog;
            if ((entry.volume_serial == null) != (entry.file_index == null)) return error.InvalidExternalSourceCatalog;
            if (next.findId(entry.id) != null or (legacy and next.findPath(entry.path) != null)) return error.InvalidExternalSourceCatalog;
            const scheme: IdentityScheme = if (legacy) blk: {
                if (entry.identity_scheme != null) return error.InvalidExternalSourceCatalog;
                break :blk .legacy;
            } else blk: {
                const name = entry.identity_scheme orelse return error.InvalidExternalSourceCatalog;
                if (std.mem.eql(u8, name, legacy_identity_scheme)) break :blk .legacy;
                if (std.mem.eql(u8, name, verified_identity_scheme) and entry.volume_serial != null) break :blk .verified;
                return error.InvalidExternalSourceCatalog;
            };
            const identity: ?file_identity.Identity = if (entry.volume_serial) |serial| .{ .volume_serial = serial, .file_index = entry.file_index.? } else null;
            var last_hash: ?[32]u8 = null;
            if (entry.last_sha256) |hex| {
                if (hex.len != 64) return error.InvalidExternalSourceCatalog;
                var digest: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&digest, hex) catch return error.InvalidExternalSourceCatalog;
                last_hash = digest;
            }
            next.items[next.count] = .{
                .id = entry.id,
                .path = try ctx.allocator.dupe(u8, entry.path),
                .identity_scheme = scheme,
                .identity = identity,
                .last_hash = last_hash,
            };
            next.count += 1;
        }
        var added: usize = 0;
        const previous_next_id = ctx.mounts.next_grant_id;
        errdefer {
            for (next.items[0..added]) |record| _ = ctx.mounts.revokeExternal(ctx.allocator, record.id);
            ctx.mounts.next_grant_id = previous_next_id;
        }
        for (next.items[0..next.count]) |record| {
            _ = try ctx.mounts.grantPersistentExternal(ctx.allocator, record.path, .read_only, record.id);
            added += 1;
        }
        self.deinit(ctx.allocator);
        self.* = next;
    }
};

const Confirmation = struct { id: u64, digest: [32]u8, path: []const u8 };

fn confirmationArguments(arg: ?[]const u8) !Confirmation {
    const text = std.mem.trim(u8, arg orelse return error.InvalidArguments, " \t\r\n");
    const first_end = std.mem.indexOfAny(u8, text, " \t") orelse return error.InvalidArguments;
    const id = std.fmt.parseInt(u64, text[0..first_end], 10) catch return error.InvalidArguments;
    if (id == 0) return error.InvalidArguments;
    const rest = std.mem.trimStart(u8, text[first_end..], " \t");
    const hash_end = std.mem.indexOfAny(u8, rest, " \t") orelse return error.InvalidArguments;
    if (hash_end != 64) return error.InvalidArguments;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, rest[0..hash_end]) catch return error.InvalidArguments;
    const path = std.mem.trim(u8, rest[hash_end..], " \t");
    if (!validPath(path)) return error.InvalidArguments;
    return .{ .id = id, .digest = digest, .path = path };
}

pub fn dispatch(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    if (std.mem.eql(u8, c.name, "source.reauthorize")) {
        const args = confirmationArguments(c.arg) catch return .failure(.invalid_arguments);
        ctx.external_sources.confirmLegacy(ctx, args.id, args.digest, args.path) catch |err| return switch (err) {
            error.InvalidExternalPath, error.ExternalConfirmationPathMismatch => .failure(.invalid_arguments),
            error.ExternalSourceNotFound, error.SourceIdentityChanged, error.SourceContentMismatch => .failure(.invalid_state),
            else => .failure(.failed),
        };
        return .success;
    }
    if (std.mem.eql(u8, c.name, "source.list")) {
        if (c.arg) |arg| {
            if (std.mem.trim(u8, arg, " \t\r\n").len != 0) return .failure(.invalid_arguments);
        }
        for (ctx.external_sources.items[0..ctx.external_sources.count]) |record| {
            std.debug.print("CUTRANS_SOURCE id={d} identity_scheme={s} confirmation_required={s} last_sha256=", .{ record.id, record.identity_scheme.text(), if (record.identity_scheme == .legacy) "true" else "false" });
            if (record.last_hash) |digest| {
                const hex = std.fmt.bytesToHex(digest, .lower);
                std.debug.print("{s}\n", .{&hex});
            } else std.debug.print("null\n", .{});
        }
        return .success;
    }
    return .failure(.unknown_command);
}

fn fixture(ctx: *RuntimeContext, resource: []const u8, data: []const u8) !void {
    ctx.init(std.testing.allocator);
    ctx.io = std.testing.io;
    ctx.paths = try @import("paths.zig").Paths.fromDirs(std.testing.allocator, .development, resource, data);
    try @import("mounts.zig").configure(ctx);
}

const TestCase = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    resource: []u8,
    data: []u8,
    source: []u8,
    catalog: []u8,

    fn init() !TestCase {
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
        const catalog = try std.fs.path.join(allocator, &.{ data, catalog_path });
        errdefer allocator.free(catalog);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = source, .data = "source" });
        return .{ .tmp = tmp, .root = root, .resource = resource, .data = data, .source = source, .catalog = catalog };
    }

    fn deinit(self: *TestCase) void {
        for ([_][]u8{ self.catalog, self.source, self.data, self.resource }) |path| std.testing.allocator.free(path);
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn open(self: *const TestCase, ctx: *RuntimeContext) !void {
        try fixture(ctx, self.resource, self.data);
    }

    fn writeLegacy(self: *const TestCase, id: u64) ![]u8 {
        const hex = std.fmt.bytesToHex(sourceDigest(), .lower);
        const text = try std.fmt.allocPrint(std.testing.allocator, "{{\"format\":\"cutrans-external-sources/1\",\"sources\":[{{\"id\":{d},\"path\":{f},\"access\":\"read_only\",\"volume_serial\":77,\"file_index\":88,\"last_sha256\":\"{s}\"}}]}}\n", .{ id, std.json.fmt(self.source, .{}), &hex });
        errdefer std.testing.allocator.free(text);
        try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, self.catalog, text);
        return text;
    }

    fn readCatalog(self: *const TestCase) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, self.catalog, std.testing.allocator, .limited(64 * 1024));
    }
};

fn sourceDigest() [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("source", &digest, .{});
    return digest;
}

const TestJunction = struct {
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, desired_access: u32, share_mode: u32, security_attributes: ?*anyopaque, creation_disposition: u32, flags_and_attributes: u32, template_file: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn CreateHardLinkW(name: [*:0]const u16, existing: [*:0]const u16, security_attributes: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn DeviceIoControl(handle: ?*anyopaque, code: u32, input: ?*const anyopaque, input_size: u32, output: ?*anyopaque, output_size: u32, returned: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;

    fn create(target: []const u8, alias: []const u8) !void {
        if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
        try std.Io.Dir.createDirAbsolute(std.testing.io, alias, .default_dir);
        errdefer std.Io.Dir.deleteDirAbsolute(std.testing.io, alias) catch {};
        var name = try std.Io.Threaded.sliceToPrefixedFileW(null, alias, .{});
        name.data[0..4].* = .{ '\\', '\\', '?', '\\' };
        const handle = CreateFileW(name.span().ptr, 0x40000000, 7, null, 3, 0x02200000, null);
        if (handle == null or handle == @as(?*anyopaque, @ptrFromInt(std.math.maxInt(usize)))) return error.TestJunctionFailed;
        defer std.os.windows.CloseHandle(@ptrCast(handle.?));
        const substitute = try std.Io.Threaded.sliceToPrefixedFileW(null, target, .{});
        const path_bytes = std.mem.sliceAsBytes(substitute.span());
        var buffer: [16 * 1024]u8 = @splat(0);
        const length = 20 + path_bytes.len;
        if (length > buffer.len) return error.NameTooLong;
        std.mem.writeInt(u32, buffer[0..4], 0xa0000003, .little);
        std.mem.writeInt(u16, buffer[4..6], @intCast(length - 8), .little);
        std.mem.writeInt(u16, buffer[10..12], @intCast(path_bytes.len), .little);
        std.mem.writeInt(u16, buffer[12..14], @intCast(path_bytes.len + 2), .little);
        @memcpy(buffer[16..][0..path_bytes.len], path_bytes);
        var returned: u32 = 0;
        if (DeviceIoControl(handle, 0x000900a4, &buffer, @intCast(length), null, 0, &returned, null) == 0) return error.TestJunctionFailed;
    }

    fn hardLink(target: []const u8, alias: []const u8) !void {
        var existing = try std.Io.Threaded.sliceToPrefixedFileW(null, target, .{});
        existing.data[0..4].* = .{ '\\', '\\', '?', '\\' };
        var name = try std.Io.Threaded.sliceToPrefixedFileW(null, alias, .{});
        name.data[0..4].* = .{ '\\', '\\', '?', '\\' };
        if (CreateHardLinkW(name.span().ptr, existing.span().ptr, null) == 0) return error.TestHardLinkFailed;
    }
};

test "ordinary file snapshots and observations are pure and require read-only grants" {
    var tc = try TestCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    var frozen = try readFileSnapshot(&ctx, tc.source);
    defer frozen.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ctx.external_sources.count);
    const id = try ctx.external_sources.importFile(&ctx, &frozen);
    try std.testing.expectEqual(@as(u64, 1), id);
    const original = try tc.readCatalog();
    defer std.testing.allocator.free(original);
    ctx.io = null;
    try std.testing.expectEqual(id, try ctx.external_sources.importFile(&ctx, &frozen));
    try std.testing.expect(ctx.mounts.revokeExternal(std.testing.allocator, id));
    try std.testing.expectError(error.ExternalGrantNotFound, ctx.external_sources.importFile(&ctx, &frozen));
    _ = try ctx.mounts.grantPersistentExternal(std.testing.allocator, frozen.path, .read_write, id);
    try std.testing.expectError(error.ReadOnlySourceRequired, ctx.external_sources.importFile(&ctx, &frozen));
    try std.testing.expectError(error.ReadOnlySourceRequired, ctx.external_sources.observeFile(&ctx, "external://1"));
    try std.testing.expect(ctx.mounts.revokeExternal(std.testing.allocator, id));
    _ = try ctx.mounts.grantPersistentExternal(std.testing.allocator, frozen.path, .read_only, id);
    ctx.io = std.testing.io;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tc.source, .data = "ordinary changed content" });
    var observed = try ctx.external_sources.observeFile(&ctx, "external://1");
    defer observed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ordinary changed content", observed.bytes);
    try std.testing.expectEqual(sourceDigest(), ctx.external_sources.items[0].last_hash.?);
    const unchanged = try tc.readCatalog();
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings(original, unchanged);
    try std.testing.expectEqual(@as(usize, 0), ctx.assets.count);
}

test "new ordinary sources reject managed roots and real Win32 junction and hard-link aliases" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tc = try TestCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const data_file = try ctx.paths.dataPath(std.testing.allocator, "managed.bin");
    defer std.testing.allocator.free(data_file);
    const resource_file = try ctx.paths.resourcePath(std.testing.allocator, "managed.bin");
    defer std.testing.allocator.free(resource_file);
    try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, data_file, "managed user evidence");
    try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, resource_file, "managed Pack evidence");
    try std.testing.expectError(error.ManagedSourceForbidden, readFileSnapshot(&ctx, data_file));
    try std.testing.expectError(error.ManagedSourceForbidden, readFileSnapshot(&ctx, resource_file));
    const alias = try std.fs.path.join(std.testing.allocator, &.{ tc.root, "data-junction" });
    defer std.testing.allocator.free(alias);
    try TestJunction.create(tc.data, alias);
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, alias) catch @panic("owned junction cleanup failed");
    const alias_file = try std.fs.path.join(std.testing.allocator, &.{ alias, "managed.bin" });
    defer std.testing.allocator.free(alias_file);
    try std.testing.expectError(error.ManagedSourceForbidden, readFileSnapshot(&ctx, alias_file));
    const resource_alias = try std.fs.path.join(std.testing.allocator, &.{ tc.root, "Pack-junction" });
    defer std.testing.allocator.free(resource_alias);
    try TestJunction.create(tc.resource, resource_alias);
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, resource_alias) catch @panic("owned junction cleanup failed");
    const resource_alias_file = try std.fs.path.join(std.testing.allocator, &.{ resource_alias, "managed.bin" });
    defer std.testing.allocator.free(resource_alias_file);
    try std.testing.expectError(error.ManagedSourceForbidden, readFileSnapshot(&ctx, resource_alias_file));
    const hard_alias = try std.fs.path.join(std.testing.allocator, &.{ tc.root, "managed-hardlink.bin" });
    defer std.testing.allocator.free(hard_alias);
    try TestJunction.hardLink(data_file, hard_alias);
    try std.testing.expectError(error.LinkedSourceUnsupported, readFileSnapshot(&ctx, hard_alias));
    try std.testing.expectEqual(@as(usize, 0), ctx.external_sources.count);
    try std.testing.expectEqual(@as(u64, 1), ctx.mounts.next_grant_id);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, data_file, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("managed user evidence", bytes);
    // Existing Source registration retains its explicit compatibility policy.
    const legacy_id = try ctx.external_sources.import(&ctx, data_file);
    try std.testing.expectEqual(@as(u64, 1), legacy_id);
    try std.testing.expectError(error.LinkedSourceUnsupported, ctx.external_sources.observeFile(&ctx, "external://1"));
}

test "authorized observation is pure across content drift and rejects replaced identities" {
    var tc = try TestCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    _ = try ctx.external_sources.import(&ctx, tc.source);
    const initial = try tc.readCatalog();
    defer std.testing.allocator.free(initial);
    var observed = try ctx.external_sources.observe(&ctx, "external://1");
    defer observed.deinit(std.testing.allocator);
    try std.testing.expectEqual(sourceDigest(), observed.digest);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tc.source, .data = "changed in place" });
    var changed = try ctx.external_sources.observe(&ctx, "external://1");
    defer changed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("changed in place", changed.bytes);
    try std.testing.expect(!std.mem.eql(u8, &changed.digest, &observed.digest));
    try std.testing.expectEqual(sourceDigest(), ctx.external_sources.items[0].last_hash.?);
    try std.testing.expectEqual(@as(usize, 0), ctx.assets.count);
    try std.testing.expectEqual(@as(usize, 1), ctx.external_sources.count);
    const after = try tc.readCatalog();
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(initial, after);

    const replacement = try std.fs.path.join(std.testing.allocator, &.{ tc.root, "replacement.bin" });
    defer std.testing.allocator.free(replacement);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = replacement, .data = "changed in place" });
    try std.Io.Dir.renameAbsolute(replacement, tc.source, std.testing.io);
    try std.testing.expectError(error.SourceIdentityChanged, ctx.external_sources.observe(&ctx, "external://1"));
    try std.testing.expectError(error.InvalidExternalGrant, ctx.external_sources.observe(&ctx, "library://1"));
    try std.testing.expectError(error.InvalidExternalGrant, ctx.external_sources.observe(&ctx, "external://0"));
    _ = try ctx.mounts.grantExternal(std.testing.allocator, tc.source, .read_only);
    try std.testing.expectError(error.ExternalSourceNotFound, ctx.external_sources.observe(&ctx, "external://2"));
    const denied = try tc.readCatalog();
    defer std.testing.allocator.free(denied);
    try std.testing.expectEqualStrings(initial, denied);
}

test "legacy observation refuses before probing and preserves original authorization bytes" {
    var tc = try TestCase.init();
    defer tc.deinit();
    const original = try tc.writeLegacy(1);
    defer std.testing.allocator.free(original);
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    try ctx.external_sources.restore(&ctx);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, tc.source);
    ctx.io = null;
    try std.testing.expectError(error.LegacyExternalIdentityUnverified, ctx.external_sources.observe(&ctx, "external://1"));
    ctx.io = std.testing.io;
    const unchanged = try tc.readCatalog();
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings(original, unchanged);
}

test "observation enforces the current persistent mount before any file IO" {
    var tc = try TestCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const id = try ctx.external_sources.import(&ctx, tc.source);
    const initial = try tc.readCatalog();
    defer std.testing.allocator.free(initial);
    ctx.io = null;
    try std.testing.expect(ctx.mounts.revokeExternal(std.testing.allocator, id));
    try std.testing.expectError(error.ExternalGrantNotFound, ctx.external_sources.observe(&ctx, "external://1"));
    const other = try std.fs.path.join(std.testing.allocator, &.{ tc.root, "not-the-authorized-file.bin" });
    defer std.testing.allocator.free(other);
    _ = try ctx.mounts.grantPersistentExternal(std.testing.allocator, other, .read_write, id);
    try std.testing.expectError(error.InvalidExternalGrant, ctx.external_sources.observe(&ctx, "external://1"));
    try std.testing.expect(ctx.mounts.revokeExternal(std.testing.allocator, id));
    _ = try ctx.mounts.grantPersistentExternal(std.testing.allocator, ctx.external_sources.items[0].path, .read_write, id);
    // Read-write is also a valid read authorization; it reaches IO only after
    // the persistent identity and its unchanged lexical locator were checked.
    try std.testing.expectError(error.IoNotReady, ctx.external_sources.observe(&ctx, "external://1"));
    ctx.io = std.testing.io;
    var observed = try ctx.external_sources.observe(&ctx, "external://1");
    defer observed.deinit(std.testing.allocator);
    try std.testing.expectEqual(sourceDigest(), observed.digest);
    const after = try tc.readCatalog();
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(initial, after);
    try std.testing.expectEqual(sourceDigest(), ctx.external_sources.items[0].last_hash.?);
}

test "Frozen reads are pure and explicit publication never rewrites old grants" {
    var tc = try TestCase.init();
    defer tc.deinit();
    const original = try tc.writeLegacy(1);
    defer std.testing.allocator.free(original);
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    try ctx.external_sources.restore(&ctx);
    var first = try readFrozen(&ctx, tc.source);
    defer first.deinit(std.testing.allocator);
    const after_probe = try tc.readCatalog();
    defer std.testing.allocator.free(after_probe);
    try std.testing.expectEqualStrings(original, after_probe);
    try std.testing.expectEqual(@as(usize, 1), ctx.external_sources.count);
    try std.testing.expectEqual(@as(usize, 0), ctx.assets.count);
    try std.testing.expectEqual(@as(u64, 2), ctx.mounts.next_grant_id);
    const first_id = try ctx.external_sources.publishFrozen(&ctx, &first);
    try std.testing.expectEqual(@as(u64, 2), first_id);
    try std.testing.expectEqual(first_id, try ctx.external_sources.publishFrozen(&ctx, &first));
    try std.testing.expectEqual(first_id, try ctx.external_sources.import(&ctx, tc.source));
    try std.testing.expectEqual(@as(usize, 2), ctx.external_sources.count);
    try std.testing.expectEqual(IdentityScheme.legacy, ctx.external_sources.items[0].identity_scheme);
    try std.testing.expectEqual(@as(u32, 77), ctx.external_sources.items[0].identity.?.volume_serial);

    const replacement = try std.fs.path.join(std.testing.allocator, &.{ tc.root, "replacement.bin" });
    defer std.testing.allocator.free(replacement);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = replacement, .data = "source" });
    try std.Io.Dir.renameAbsolute(replacement, tc.source, std.testing.io);
    var second = try readFrozen(&ctx, tc.source);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!identityEqual(first.identity, second.identity));
    try std.testing.expectEqual(@as(u64, 3), try ctx.external_sources.publishFrozen(&ctx, &second));
    try std.testing.expectEqual(first.identity, ctx.external_sources.items[1].identity.?);
    try std.testing.expectEqual(@as(u64, 3), try ctx.external_sources.import(&ctx, tc.source));
    var restored: RuntimeContext = undefined;
    try tc.open(&restored);
    defer restored.deinit();
    try restored.external_sources.restore(&restored);
    try std.testing.expectEqual(@as(usize, 3), restored.external_sources.count);
    try std.testing.expectEqual(first.identity, restored.external_sources.items[1].identity.?);
    try std.testing.expectEqual(second.identity, restored.external_sources.items[2].identity.?);
    try std.testing.expectError(error.LegacyExternalIdentityUnverified, restored.external_sources.requireVerified(try @import("vne").uri.parse("external://1")));
}

test "Frozen publication refuses corrupted bytes and a full immutable grant budget" {
    var tc = try TestCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    var first = try readFrozen(&ctx, tc.source);
    defer first.deinit(std.testing.allocator);
    first.digest[0] ^= 1;
    try std.testing.expectError(error.SourceContentMismatch, ctx.external_sources.publishFrozen(&ctx, &first));
    try std.testing.expectEqual(@as(usize, 0), ctx.external_sources.count);
    try std.testing.expectEqual(@as(u64, 1), ctx.mounts.next_grant_id);
    first.digest[0] ^= 1;
    _ = try ctx.external_sources.publishFrozen(&ctx, &first);
    for (0..7) |index| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "grant-{d}.bin", .{index});
        defer std.testing.allocator.free(name);
        try tc.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "source" });
        const path = try std.fs.path.join(std.testing.allocator, &.{ tc.root, name });
        defer std.testing.allocator.free(path);
        var candidate = try readFrozen(&ctx, path);
        defer candidate.deinit(std.testing.allocator);
        _ = try ctx.external_sources.publishFrozen(&ctx, &candidate);
    }
    const previous = try tc.readCatalog();
    defer std.testing.allocator.free(previous);
    const ninth = try std.fs.path.join(std.testing.allocator, &.{ tc.root, "ninth.bin" });
    defer std.testing.allocator.free(ninth);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ninth, .data = "source" });
    var candidate = try readFrozen(&ctx, ninth);
    defer candidate.deinit(std.testing.allocator);
    try std.testing.expectError(error.ExternalGrantTableFull, ctx.external_sources.publishFrozen(&ctx, &candidate));
    try std.testing.expectEqual(@as(usize, 8), ctx.external_sources.count);
    try std.testing.expectEqual(@as(u64, 9), ctx.mounts.next_grant_id);
    const after = try tc.readCatalog();
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(previous, after);
}

test "explicitly confirming an old legacy ID after rebind preserves both grant aliases" {
    var tc = try TestCase.init();
    defer tc.deinit();
    const original = try tc.writeLegacy(1);
    defer std.testing.allocator.free(original);
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    try ctx.external_sources.restore(&ctx);
    var candidate = try readFrozen(&ctx, tc.source);
    defer candidate.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), try ctx.external_sources.publishFrozen(&ctx, &candidate));
    try ctx.external_sources.confirmLegacy(&ctx, 1, candidate.digest, tc.source);
    var restored: RuntimeContext = undefined;
    try tc.open(&restored);
    defer restored.deinit();
    try restored.external_sources.restore(&restored);
    try std.testing.expectEqual(@as(usize, 2), restored.external_sources.count);
    try restored.external_sources.requireVerified(try @import("vne").uri.parse("external://1"));
    try restored.external_sources.requireVerified(try @import("vne").uri.parse("external://2"));
    try std.testing.expectEqual(restored.external_sources.items[0].identity.?, restored.external_sources.items[1].identity.?);
}

test "v1 identities remain evidence and deny implicit authorization without writing" {
    var tc = try TestCase.init();
    defer tc.deinit();
    const original = try tc.writeLegacy(1);
    defer std.testing.allocator.free(original);
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    try ctx.external_sources.restore(&ctx);
    const uri = try @import("vne").uri.parse("external://1");
    try std.testing.expectEqual(IdentityScheme.legacy, ctx.external_sources.items[0].identity_scheme);
    try std.testing.expectEqual(@as(u32, 77), ctx.external_sources.items[0].identity.?.volume_serial);
    try std.testing.expectEqual(@as(u64, 88), ctx.external_sources.items[0].identity.?.file_index);
    try std.testing.expectError(error.LegacyExternalIdentityUnverified, ctx.external_sources.requireVerified(uri));
    try std.testing.expectError(error.LegacyExternalIdentityUnverified, ctx.external_sources.import(&ctx, tc.source));
    try std.testing.expectError(error.LegacyExternalIdentityUnverified, ctx.external_sources.noteRead(&ctx, uri, .{ .volume_serial = 77, .file_index = 88 }, sourceDigest()));
    const after = try tc.readCatalog();
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(original, after);
    // A separate explicit temporary grant keeps its existing authorization.
    try ctx.external_sources.requireVerified(try @import("vne").uri.parse("external://7"));
    try ctx.external_sources.requireVerified(try @import("vne").uri.parse("library://1"));
    try std.testing.expectEqual(command.Code.invalid_arguments, dispatch(.{ .name = "source.reauthorize", .arg = "1 xyz C:/source" }, &ctx).code);
    try std.testing.expectEqual(command.Code.ok, dispatch(.{ .name = "source.list" }, &ctx).code);
}

test "legacy confirmation rejects mismatches and rolls memory back when publication fails" {
    var tc = try TestCase.init();
    defer tc.deinit();
    const original = try tc.writeLegacy(1);
    defer std.testing.allocator.free(original);
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    try ctx.external_sources.restore(&ctx);
    const other = try std.fs.path.join(std.testing.allocator, &.{ tc.root, "other.bin" });
    defer std.testing.allocator.free(other);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = other, .data = "source" });
    try std.testing.expectError(error.ExternalConfirmationPathMismatch, ctx.external_sources.confirmLegacy(&ctx, 1, sourceDigest(), other));
    var wrong = sourceDigest();
    wrong[0] ^= 1;
    try std.testing.expectError(error.SourceContentMismatch, ctx.external_sources.confirmLegacy(&ctx, 1, wrong, tc.source));
    try std.testing.expectEqual(IdentityScheme.legacy, ctx.external_sources.items[0].identity_scheme);
    const unchanged = try tc.readCatalog();
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings(original, unchanged);

    const saved = try std.fs.path.join(std.testing.allocator, &.{ tc.data, "session", "external-sources.saved" });
    defer std.testing.allocator.free(saved);
    try std.Io.Dir.renameAbsolute(tc.catalog, saved, std.testing.io);
    try std.Io.Dir.createDirAbsolute(std.testing.io, tc.catalog, .default_dir);
    if (ctx.external_sources.confirmLegacy(&ctx, 1, sourceDigest(), tc.source)) |_| {
        return error.TestExpectedError;
    } else |_| {}
    try std.testing.expectEqual(IdentityScheme.legacy, ctx.external_sources.items[0].identity_scheme);
    try std.testing.expectEqual(@as(u32, 77), ctx.external_sources.items[0].identity.?.volume_serial);
    try std.testing.expectEqual(@as(u64, 88), ctx.external_sources.items[0].identity.?.file_index);
    try std.testing.expectEqual(sourceDigest(), ctx.external_sources.items[0].last_hash.?);
    try std.Io.Dir.deleteDirAbsolute(std.testing.io, tc.catalog);
    try std.Io.Dir.renameAbsolute(saved, tc.catalog, std.testing.io);

    const hex = std.fmt.bytesToHex(sourceDigest(), .lower);
    const arg = try std.fmt.allocPrint(std.testing.allocator, "1 {s} {s}", .{ &hex, tc.source });
    defer std.testing.allocator.free(arg);
    try std.testing.expectEqual(command.Code.ok, dispatch(.{ .name = "source.reauthorize", .arg = arg }, &ctx).code);
    try std.testing.expectEqual(IdentityScheme.verified, ctx.external_sources.items[0].identity_scheme);
    const verified = try tc.readCatalog();
    defer std.testing.allocator.free(verified);
    try std.testing.expect(std.mem.indexOf(u8, verified, "cutrans-external-sources/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, verified, verified_identity_scheme) != null);
    try ctx.external_sources.confirmLegacy(&ctx, 1, sourceDigest(), tc.source);
    const replay = try tc.readCatalog();
    defer std.testing.allocator.free(replay);
    try std.testing.expectEqualStrings(verified, replay);
}

test "verified confirmation is a byte-noop and cannot reauthorize an atomic replacement" {
    var tc = try TestCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    _ = try ctx.external_sources.import(&ctx, tc.source);
    const initial = try tc.readCatalog();
    defer std.testing.allocator.free(initial);
    // Observation hashes are not authorization. Reconfirmation does not write
    // even if an earlier observer changed last_hash in this process.
    ctx.external_sources.items[0].last_hash = @as([32]u8, @splat(0x5a));
    try ctx.external_sources.confirmLegacy(&ctx, 1, sourceDigest(), tc.source);
    try std.testing.expectEqual(@as([32]u8, @splat(0x5a)), ctx.external_sources.items[0].last_hash.?);
    const noop = try tc.readCatalog();
    defer std.testing.allocator.free(noop);
    try std.testing.expectEqualStrings(initial, noop);
    const replacement = try std.fs.path.join(std.testing.allocator, &.{ tc.root, "replacement.bin" });
    defer std.testing.allocator.free(replacement);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = replacement, .data = "source" });
    try std.Io.Dir.renameAbsolute(replacement, tc.source, std.testing.io);
    try std.testing.expectError(error.SourceIdentityChanged, ctx.external_sources.confirmLegacy(&ctx, 1, sourceDigest(), tc.source));
    try std.testing.expectError(error.SourceIdentityChanged, ctx.external_sources.import(&ctx, tc.source));
    const denied = try tc.readCatalog();
    defer std.testing.allocator.free(denied);
    try std.testing.expectEqualStrings(initial, denied);
}

test "mixed v2 catalogs preserve legacy evidence and require explicit verified schemes" {
    var tc = try TestCase.init();
    defer tc.deinit();
    const original = try tc.writeLegacy(1);
    defer std.testing.allocator.free(original);
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    try ctx.external_sources.restore(&ctx);
    const other = try std.fs.path.join(std.testing.allocator, &.{ tc.root, "new-source.bin" });
    defer std.testing.allocator.free(other);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = other, .data = "source" });
    try std.testing.expectEqual(@as(u64, 2), try ctx.external_sources.import(&ctx, other));
    const mixed = try tc.readCatalog();
    defer std.testing.allocator.free(mixed);
    try std.testing.expect(std.mem.indexOf(u8, mixed, legacy_identity_scheme) != null);
    try std.testing.expect(std.mem.indexOf(u8, mixed, verified_identity_scheme) != null);
    var restored: RuntimeContext = undefined;
    try tc.open(&restored);
    defer restored.deinit();
    try restored.external_sources.restore(&restored);
    try std.testing.expectEqual(@as(usize, 2), restored.external_sources.count);
    try std.testing.expectEqual(IdentityScheme.legacy, restored.external_sources.items[0].identity_scheme);
    try std.testing.expectEqual(@as(u32, 77), restored.external_sources.items[0].identity.?.volume_serial);
    try std.testing.expectEqual(@as(u64, 88), restored.external_sources.items[0].identity.?.file_index);
    try std.testing.expectEqual(IdentityScheme.verified, restored.external_sources.items[1].identity_scheme);
    try std.testing.expectError(error.LegacyExternalIdentityUnverified, restored.external_sources.requireVerified(try @import("vne").uri.parse("external://1")));
    try restored.external_sources.requireVerified(try @import("vne").uri.parse("external://2"));

    const invalid = try std.fmt.allocPrint(std.testing.allocator, "{{\"format\":\"cutrans-external-sources/2\",\"sources\":[{{\"id\":1,\"path\":{f},\"access\":\"read_only\",\"identity_scheme\":\"win32-file-id/1\"}}]}}", .{std.json.fmt(tc.source, .{})});
    defer std.testing.allocator.free(invalid);
    try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, tc.catalog, invalid);
    var rejected: RuntimeContext = undefined;
    try tc.open(&rejected);
    defer rejected.deinit();
    try std.testing.expectError(error.InvalidExternalSourceCatalog, rejected.external_sources.restore(&rejected));
    try std.testing.expectEqual(@as(usize, 0), rejected.external_sources.count);
    try std.testing.expectError(error.ExternalGrantNotFound, rejected.mounts.resolveAlloc(std.testing.allocator, try @import("vne").uri.parse("external://1")));
}

test "external catalog IDs exhaust without wrap and restore failure rolls staged mounts back" {
    var tc = try TestCase.init();
    defer tc.deinit();
    const original = try tc.writeLegacy(std.math.maxInt(u64));
    defer std.testing.allocator.free(original);
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    try ctx.external_sources.restore(&ctx);
    try std.testing.expectEqual(@as(u64, 0), ctx.mounts.next_grant_id);
    const other = try std.fs.path.join(std.testing.allocator, &.{ tc.root, "other.bin" });
    defer std.testing.allocator.free(other);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = other, .data = "source" });
    try std.testing.expectError(error.ExternalGrantIdExhausted, ctx.external_sources.import(&ctx, other));
    try std.testing.expectEqual(@as(usize, 1), ctx.external_sources.count);
    try std.testing.expectEqual(std.math.maxInt(u64), ctx.external_sources.items[0].id);
    const after = try tc.readCatalog();
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(original, after);

    const manifest = try std.fmt.allocPrint(std.testing.allocator, "{{\"format\":\"cutrans-external-sources/1\",\"sources\":[{{\"id\":1,\"path\":{f},\"access\":\"read_only\"}},{{\"id\":2,\"path\":{f},\"access\":\"read_only\"}}]}}", .{ std.json.fmt(tc.source, .{}), std.json.fmt(other, .{}) });
    defer std.testing.allocator.free(manifest);
    try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, tc.catalog, manifest);
    var rejected: RuntimeContext = undefined;
    try tc.open(&rejected);
    defer rejected.deinit();
    _ = try rejected.mounts.grantPersistentExternal(std.testing.allocator, other, .read_only, 2);
    const before_clock = rejected.mounts.next_grant_id;
    try std.testing.expectError(error.DuplicateExternalGrant, rejected.external_sources.restore(&rejected));
    try std.testing.expectEqual(@as(usize, 0), rejected.external_sources.count);
    try std.testing.expectEqual(before_clock, rejected.mounts.next_grant_id);
    try std.testing.expectError(error.ExternalGrantNotFound, rejected.mounts.resolveAlloc(std.testing.allocator, try @import("vne").uri.parse("external://1")));
    const still_existing = try rejected.mounts.resolveAlloc(std.testing.allocator, try @import("vne").uri.parse("external://2"));
    defer std.testing.allocator.free(still_existing.path);
    try std.testing.expectEqualStrings(other, still_existing.path);
}

test "external source grants restore intent without reviving the Station" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "source.png" });
    defer std.testing.allocator.free(source);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = source, .data = "source" });
    var ctx: RuntimeContext = undefined;
    try fixture(&ctx, resource, data);
    defer ctx.deinit();
    const first = try ctx.external_sources.import(&ctx, source);
    const second = try ctx.external_sources.import(&ctx, source);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), ctx.external_sources.count);
    try std.testing.expectEqual(@as(usize, 0), ctx.assets.count);
    try std.testing.expect((try ctx.mounts.isPersistentExternal(try @import("vne").uri.parse("external://1"))));

    var restored: RuntimeContext = undefined;
    try fixture(&restored, resource, data);
    defer restored.deinit();
    try restored.external_sources.restore(&restored);
    try std.testing.expectEqual(@as(usize, 1), restored.external_sources.count);
    try std.testing.expect((try restored.mounts.isPersistentExternal(try @import("vne").uri.parse("external://1"))));
    const resolved = try restored.mounts.resolveAlloc(std.testing.allocator, try @import("vne").uri.parse("external://1"));
    defer std.testing.allocator.free(resolved.path);
    try std.testing.expectEqualStrings(source, resolved.path);
    try std.testing.expectEqual(@as(usize, 0), restored.assets.count);
    const actual = try @import("ports").file_identity.query(std.testing.io, source);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("source", &digest, .{});
    try restored.external_sources.noteRead(&restored, try @import("vne").uri.parse("external://1"), actual, digest);
    restored.external_sources.items[0].identity.?.volume_serial ^= 1;
    try std.testing.expectError(error.SourceIdentityChanged, restored.external_sources.noteRead(&restored, try @import("vne").uri.parse("external://1"), actual, digest));

    const catalog_file = try std.fs.path.join(std.testing.allocator, &.{ data, catalog_path });
    defer std.testing.allocator.free(catalog_file);
    try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, catalog_file, "not-json");
    var corrupted: RuntimeContext = undefined;
    try fixture(&corrupted, resource, data);
    defer corrupted.deinit();
    try std.testing.expectError(error.InvalidExternalSourceCatalog, corrupted.external_sources.restore(&corrupted));
}
