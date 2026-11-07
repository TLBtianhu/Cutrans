//! VM 资源库:稳定 id、引用/拥有状态与显式独立化;不是内存 Station 或同步器。

const std = @import("std");
const RuntimeContext = @import("context.zig").Context;
const storage = @import("storage.zig");
const versions = @import("resource_versions.zig");
const external_sources = @import("external_sources.zig");

pub const catalog_path = "library/catalog.json";
pub const validateCandidate = @import("png_limits.zig").validateCandidate;

pub const Kind = enum { reference, owned };
pub const Provenance = enum { external, created, detached };

pub const Folder = struct {
    id: u64,
    parent_id: u64,
    label: []u8,
};

pub const Resource = struct {
    id: u64,
    parent_id: u64 = 0,
    label: []u8,
    kind: Kind,
    provenance: Provenance,
    source_uri: []u8,
    content_hash: [32]u8,
};

pub const Node = union(enum) {
    folder: *const Folder,
    resource: *const Resource,
};

const FolderEntry = struct {
    id: u64,
    parent_id: u64,
    label: []const u8,
};

const Entry = struct {
    id: u64,
    parent_id: u64 = 0,
    label: []const u8,
    kind: []const u8,
    provenance: []const u8,
    source: []const u8,
    sha256: []const u8,
};

const Manifest = struct {
    format: []const u8,
    next_id: u64,
    folders: []FolderEntry = &.{},
    resources: []Entry,
};

fn hash(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn validLabel(label: []const u8) !void {
    if (label.len == 0 or label.len > 128 or std.fs.path.isAbsolute(label) or std.mem.indexOf(u8, label, "..") != null or std.mem.indexOfScalar(u8, label, '/') != null or std.mem.indexOfScalar(u8, label, '\\') != null or std.mem.indexOfScalar(u8, label, ':') != null or std.mem.indexOfScalar(u8, label, 0) != null) return error.InvalidResourceLabel;
}

fn externalUri(source: []const u8) !@import("vne").uri.Uri {
    const uri = @import("vne").uri.parse(source) catch return error.InvalidResourceLibrary;
    if (uri.root != .external) return error.InvalidResourceLibrary;
    for (uri.body) |byte| if (byte < '0' or byte > '9') return error.InvalidResourceLibrary;
    const id = std.fmt.parseInt(u64, uri.body, 10) catch return error.InvalidResourceLibrary;
    if (id == 0) return error.InvalidResourceLibrary;
    return uri;
}

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime key: []const u8, value: []const u8) !void {
    try appendFmt(out, allocator, ",\"{s}\":{f}", .{ key, std.json.fmt(value, .{}) });
}

pub const Catalog = struct {
    items: [32]Resource = undefined,
    count: usize = 0,
    folders: [32]Folder = undefined,
    folder_count: usize = 0,
    next_id: u64 = 1,
    revision: u64 = 0,

    const Mutation = struct {
        revision: u64,
        assets_revision: ?u64,

        fn publish(self: Mutation, catalog: *Catalog, ctx: *RuntimeContext) void {
            catalog.revision = self.revision;
            if (self.assets_revision) |value| ctx.assets.revision = value;
        }
    };

    fn prepareMutation(self: *const Catalog, ctx: *RuntimeContext, changes_assets: bool) !Mutation {
        return .{
            .revision = std.math.add(u64, self.revision, 1) catch return error.ResourceRevisionExhausted,
            .assets_revision = if (changes_assets) std.math.add(u64, ctx.assets.revision, 1) catch return error.AssetRevisionExhausted else null,
        };
    }

    fn prepareAppend(self: *const Catalog, label: []const u8, parent_id: u64) !u64 {
        if (self.count == self.items.len) return error.ResourceLibraryFull;
        if (parent_id != 0 and self.getFolder(parent_id) == null) return error.InvalidResourceHierarchy;
        try validLabel(label);
        if (self.next_id == 0) return error.ResourceIdExhausted;
        return std.math.add(u64, self.next_id, 1) catch return error.ResourceIdExhausted;
    }

    fn retainBytes(ctx: *RuntimeContext, id: u64, digest: [32]u8, bytes: []const u8) !void {
        const io = ctx.io orelse return error.IoNotReady;
        var dir = try ctx.paths.openDataDir(io, ctx.allocator);
        defer dir.close(io);
        try versions.retain(dir, io, ctx.allocator, id, digest, bytes);
    }

    pub fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        for (self.items[0..self.count]) |item| {
            allocator.free(item.label);
            allocator.free(item.source_uri);
        }
        for (self.folders[0..self.folder_count]) |folder| allocator.free(folder.label);
        self.* = .{};
    }

    pub fn get(self: *const Catalog, id: u64) ?*const Resource {
        for (self.items[0..self.count]) |*item| {
            if (item.id == id) return item;
        }
        return null;
    }

    pub fn getFolder(self: *const Catalog, id: u64) ?*const Folder {
        for (self.folders[0..self.folder_count]) |*folder| {
            if (folder.id == id) return folder;
        }
        return null;
    }

    pub fn getNode(self: *const Catalog, id: u64) ?Node {
        if (self.getFolder(id)) |folder| return .{ .folder = folder };
        if (self.get(id)) |resource| return .{ .resource = resource };
        return null;
    }

    pub fn nodeLabel(self: *const Catalog, id: u64) ?[]const u8 {
        const node = self.getNode(id) orelse return null;
        return switch (node) {
            .folder => |folder| folder.label,
            .resource => |resource| resource.label,
        };
    }

    fn getMut(self: *Catalog, id: u64) ?*Resource {
        for (self.items[0..self.count]) |*item| {
            if (item.id == id) return item;
        }
        return null;
    }

    fn getFolderMut(self: *Catalog, id: u64) ?*Folder {
        for (self.folders[0..self.folder_count]) |*folder| {
            if (folder.id == id) return folder;
        }
        return null;
    }

    fn labelMut(self: *Catalog, id: u64) ?*[]u8 {
        if (self.getFolderMut(id)) |folder| return &folder.label;
        if (self.getMut(id)) |resource| return &resource.label;
        return null;
    }

    fn parentMut(self: *Catalog, id: u64) ?*u64 {
        if (self.getFolderMut(id)) |folder| return &folder.parent_id;
        if (self.getMut(id)) |resource| return &resource.parent_id;
        return null;
    }

    fn validateHierarchy(self: *const Catalog) !void {
        for (self.folders[0..self.folder_count]) |folder| {
            if (folder.parent_id == folder.id) return error.InvalidResourceHierarchy;
            var parent_id = folder.parent_id;
            var depth: usize = 0;
            while (parent_id != 0) {
                if (parent_id == folder.id) return error.InvalidResourceHierarchy;
                const parent = self.getFolder(parent_id) orelse return error.InvalidResourceHierarchy;
                parent_id = parent.parent_id;
                depth += 1;
                if (depth > self.folder_count) return error.InvalidResourceHierarchy;
            }
        }
        for (self.items[0..self.count]) |item| {
            if (item.parent_id != 0 and self.getFolder(item.parent_id) == null) return error.InvalidResourceHierarchy;
        }
    }

    fn contentPath(self: *const Catalog, ctx: *RuntimeContext, id: u64) ![]u8 {
        _ = self;
        const relative = try std.fmt.allocPrint(ctx.allocator, "library/content/{d}.bin", .{id});
        defer ctx.allocator.free(relative);
        return ctx.paths.dataPath(ctx.allocator, relative);
    }

    fn save(self: *const Catalog, ctx: *RuntimeContext) !void {
        const io = ctx.io orelse return error.IoNotReady;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ctx.allocator);
        try appendFmt(&out, ctx.allocator, "{{\"format\":\"cutrans-resource-library/2\",\"next_id\":{d},\"folders\":[", .{self.next_id});
        for (self.folders[0..self.folder_count], 0..) |folder, index| {
            if (index != 0) try out.appendSlice(ctx.allocator, ",");
            try appendFmt(&out, ctx.allocator, "{{\"id\":{d},\"parent_id\":{d}", .{ folder.id, folder.parent_id });
            try appendJsonString(&out, ctx.allocator, "label", folder.label);
            try out.appendSlice(ctx.allocator, "}");
        }
        try out.appendSlice(ctx.allocator, "],\"resources\":[");
        for (self.items[0..self.count], 0..) |item, index| {
            if (index != 0) try out.appendSlice(ctx.allocator, ",");
            try appendFmt(&out, ctx.allocator, "{{\"id\":{d},\"parent_id\":{d}", .{ item.id, item.parent_id });
            try appendJsonString(&out, ctx.allocator, "label", item.label);
            try appendJsonString(&out, ctx.allocator, "kind", @tagName(item.kind));
            try appendJsonString(&out, ctx.allocator, "provenance", @tagName(item.provenance));
            try appendJsonString(&out, ctx.allocator, "source", item.source_uri);
            const digest = std.fmt.bytesToHex(item.content_hash, .lower);
            try appendJsonString(&out, ctx.allocator, "sha256", &digest);
            try out.appendSlice(ctx.allocator, "}");
        }
        try out.appendSlice(ctx.allocator, "]}\n");
        const path = try ctx.paths.dataPath(ctx.allocator, catalog_path);
        defer ctx.allocator.free(path);
        try storage.writeAtomic(std.Io.Dir.cwd(), io, path, out.items);
    }

    fn append(self: *Catalog, ctx: *RuntimeContext, label: []const u8, kind: Kind, provenance: Provenance, source_uri: []const u8, content_hash: [32]u8, parent_id: u64) !u64 {
        const mutation = try self.prepareMutation(ctx, true);
        const next_id = try self.prepareAppend(label, parent_id);
        const id = self.next_id;
        const owned_label = try ctx.allocator.dupe(u8, label);
        const owned_source = ctx.allocator.dupe(u8, source_uri) catch |err| {
            ctx.allocator.free(owned_label);
            return err;
        };
        self.items[self.count] = .{
            .id = id,
            .parent_id = parent_id,
            .label = owned_label,
            .kind = kind,
            .provenance = provenance,
            .source_uri = owned_source,
            .content_hash = content_hash,
        };
        self.count += 1;
        errdefer {
            ctx.allocator.free(self.items[self.count - 1].label);
            ctx.allocator.free(self.items[self.count - 1].source_uri);
            self.count -= 1;
        }
        self.next_id = next_id;
        errdefer self.next_id = id;
        try self.save(ctx);
        mutation.publish(self, ctx);
        return id;
    }

    pub fn createFolder(self: *Catalog, ctx: *RuntimeContext, parent_id: u64, label: []const u8) !u64 {
        if (self.folder_count == self.folders.len) return error.ResourceLibraryFull;
        if (parent_id != 0 and self.getFolder(parent_id) == null) return error.InvalidResourceHierarchy;
        try validLabel(label);
        const mutation = try self.prepareMutation(ctx, false);
        if (self.next_id == 0) return error.ResourceIdExhausted;
        const next_id = std.math.add(u64, self.next_id, 1) catch return error.ResourceIdExhausted;
        const id = self.next_id;
        self.folders[self.folder_count] = .{
            .id = id,
            .parent_id = parent_id,
            .label = try ctx.allocator.dupe(u8, label),
        };
        self.folder_count += 1;
        errdefer {
            self.folder_count -= 1;
            ctx.allocator.free(self.folders[self.folder_count].label);
        }
        self.next_id = next_id;
        errdefer self.next_id = id;
        try self.save(ctx);
        mutation.publish(self, ctx);
        return id;
    }

    pub fn rename(self: *Catalog, ctx: *RuntimeContext, id: u64, label: []const u8) !void {
        try validLabel(label);
        const current = self.labelMut(id) orelse return error.ResourceNotFound;
        if (std.mem.eql(u8, current.*, label)) return;
        const mutation = try self.prepareMutation(ctx, false);
        const replacement = try ctx.allocator.dupe(u8, label);
        errdefer ctx.allocator.free(replacement);
        const previous = current.*;
        current.* = replacement;
        self.save(ctx) catch |err| {
            current.* = previous;
            return err;
        };
        ctx.allocator.free(previous);
        mutation.publish(self, ctx);
    }

    pub fn move(self: *Catalog, ctx: *RuntimeContext, id: u64, parent_id: u64) !void {
        if (id == 0) return error.InvalidResourceHierarchy;
        if (parent_id != 0 and self.getFolder(parent_id) == null) return error.InvalidResourceHierarchy;
        if (self.getFolder(id) != null) {
            var cursor = parent_id;
            var depth: usize = 0;
            while (cursor != 0) {
                if (cursor == id) return error.InvalidResourceHierarchy;
                const parent = self.getFolder(cursor) orelse return error.InvalidResourceHierarchy;
                cursor = parent.parent_id;
                depth += 1;
                if (depth > self.folder_count) return error.InvalidResourceHierarchy;
            }
        }
        const current = self.parentMut(id) orelse return error.ResourceNotFound;
        if (current.* == parent_id) return;
        const mutation = try self.prepareMutation(ctx, false);
        const previous = current.*;
        current.* = parent_id;
        self.save(ctx) catch |err| {
            current.* = previous;
            return err;
        };
        mutation.publish(self, ctx);
    }

    pub fn importExternal(self: *Catalog, ctx: *RuntimeContext, path: []const u8) !u64 {
        _ = try self.prepareMutation(ctx, true);
        if (self.next_id == 0 or self.next_id == std.math.maxInt(u64)) return error.ResourceIdExhausted;
        const grant = try ctx.external_sources.import(ctx, path);
        const uri = try std.fmt.allocPrint(ctx.allocator, "external://{d}", .{grant});
        defer ctx.allocator.free(uri);
        var loaded = try @import("assets.zig").readStandalone(ctx, uri);
        defer loaded.deinit(ctx.allocator);
        for (self.items[0..self.count]) |item| {
            if (item.kind != .reference or !std.mem.eql(u8, item.source_uri, uri)) continue;
            if (!std.mem.eql(u8, &item.content_hash, &loaded.source.content_hash)) return error.ResourceContentChanged;
            return item.id;
        }
        return self.append(ctx, std.fs.path.basename(path), .reference, .external, uri, loaded.source.content_hash, 0);
    }

    /// Register complete file bytes without format interpretation. The Source
    /// boundary rejects managed roots and captures identity and bytes together.
    pub fn registerFile(self: *Catalog, ctx: *RuntimeContext, path: []const u8) !u64 {
        var frozen = try external_sources.readFileSnapshot(ctx, path);
        defer frozen.deinit(ctx.allocator);
        return self.registerFrozenFile(ctx, &frozen);
    }

    /// A managed request may reuse its already validated snapshot. Existing
    /// resource identities remain reusable even when no new IDs/slots remain.
    pub fn registerFrozenFile(self: *Catalog, ctx: *RuntimeContext, frozen: *const external_sources.Frozen) !u64 {
        if (frozen.bytes.len > versions.max_file_bytes) return error.ResourceVersionBudgetExceeded;
        if (!std.mem.eql(u8, &frozen.digest, &hash(frozen.bytes))) return error.SourceContentMismatch;
        if (ctx.external_sources.findFile(frozen)) |grant| {
            var buffer: [64]u8 = undefined;
            const uri = try std.fmt.bufPrint(&buffer, "external://{d}", .{grant});
            for (self.items[0..self.count]) |item| {
                if (item.kind != .reference or !std.mem.eql(u8, item.source_uri, uri)) continue;
                if (!std.mem.eql(u8, &item.content_hash, &frozen.digest)) return error.ResourceContentChanged;
                // Metadata identity alone is not authorization. An existing
                // grant must still be persistent, read-only and bound to the
                // same locator; this validated reuse does not perform IO.
                if (try ctx.external_sources.importFile(ctx, frozen) != grant) return error.InvalidExternalGrant;
                return item.id;
            }
        }
        _ = try self.prepareMutation(ctx, true);
        const label = std.fs.path.basename(frozen.path);
        _ = try self.prepareAppend(label, 0);
        const grant = try ctx.external_sources.importFile(ctx, frozen);
        var buffer: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buffer, "external://{d}", .{grant});
        // A published Source may survive catalog failure as an unused dependency;
        // the catalog still rolls back atomically, without deleting source data.
        return self.append(ctx, label, .reference, .external, uri, frozen.digest, 0);
    }

    pub fn create(self: *Catalog, ctx: *RuntimeContext, label: []const u8, bytes: []const u8) !u64 {
        _ = try self.prepareMutation(ctx, true);
        _ = try self.prepareAppend(label, 0);
        const id = self.next_id;
        const digest = hash(bytes);
        try retainBytes(ctx, id, digest, bytes);
        return self.append(ctx, label, .owned, .created, "", digest, 0);
    }

    pub fn refresh(self: *Catalog, ctx: *RuntimeContext, id: u64) !bool {
        const item = self.getMut(id) orelse return error.ResourceNotFound;
        if (item.kind != .reference) return error.InvalidResourceState;
        const mutation = try self.prepareMutation(ctx, true);
        var loaded = try @import("assets.zig").readStandalone(ctx, item.source_uri);
        defer loaded.deinit(ctx.allocator);
        if (std.mem.eql(u8, &item.content_hash, &loaded.source.content_hash)) return false;
        const previous = item.content_hash;
        item.content_hash = loaded.source.content_hash;
        self.save(ctx) catch |err| {
            item.content_hash = previous;
            return err;
        };
        mutation.publish(self, ctx);
        return true;
    }

    pub fn detach(self: *Catalog, ctx: *RuntimeContext, id: u64) !void {
        const item = self.getMut(id) orelse return error.ResourceNotFound;
        if (item.kind == .owned) return;
        const mutation = try self.prepareMutation(ctx, true);
        if (ctx.assets.findResourceHead(id, item.content_hash)) |resident| {
            // Complete Station bytes remain usable even after the original
            // disappears. An older resident version never substitutes for the
            // current library head, and borrowing does not change its lease.
            try retainBytes(ctx, id, item.content_hash, resident.bytes);
        } else {
            var loaded = try @import("assets.zig").readStandalone(ctx, item.source_uri);
            defer loaded.deinit(ctx.allocator);
            if (!std.mem.eql(u8, &item.content_hash, &loaded.source.content_hash)) return error.ResourceContentChanged;
            try retainBytes(ctx, id, item.content_hash, loaded.bytes);
        }
        const old_kind = item.kind;
        const old_provenance = item.provenance;
        item.kind = .owned;
        item.provenance = .detached;
        self.save(ctx) catch |err| {
            item.kind = old_kind;
            item.provenance = old_provenance;
            return err;
        };
        mutation.publish(self, ctx);
    }

    pub fn rebind(self: *Catalog, ctx: *RuntimeContext, id: u64, mode: @import("vne").resource_api.Mode, frozen: *const external_sources.Frozen) !void {
        const item = self.getMut(id) orelse return error.ResourceNotFound;
        if (item.kind != .reference) return error.InvalidResourceState;
        const mutation = try self.prepareMutation(ctx, true);
        if (mode == .relocate and !std.mem.eql(u8, &item.content_hash, &frozen.digest)) return error.ResourceContentChanged;
        try validateCandidate(ctx.allocator, frozen.bytes);
        if (!std.mem.eql(u8, &hash(frozen.bytes), &frozen.digest)) return error.SourceContentMismatch;
        // These immutable dependencies can survive a later catalog failure.
        try retainBytes(ctx, id, frozen.digest, frozen.bytes);
        const grant = try ctx.external_sources.publishFrozen(ctx, frozen);
        const uri = try std.fmt.allocPrint(ctx.allocator, "external://{d}", .{grant});
        errdefer ctx.allocator.free(uri);
        if (std.mem.eql(u8, item.source_uri, uri) and std.mem.eql(u8, &item.content_hash, &frozen.digest)) {
            ctx.allocator.free(uri);
            return;
        }
        const previous_uri = item.source_uri;
        const previous_hash = item.content_hash;
        item.source_uri = uri;
        item.content_hash = frozen.digest;
        self.save(ctx) catch |err| {
            item.source_uri = previous_uri;
            item.content_hash = previous_hash;
            return err;
        };
        ctx.allocator.free(previous_uri);
        mutation.publish(self, ctx);
    }

    fn readOwnedBytes(self: *Catalog, ctx: *RuntimeContext, id: u64, digest: [32]u8) ![]u8 {
        const io = ctx.io orelse return error.IoNotReady;
        const retained: ?[]u8 = blk: {
            var dir = ctx.paths.openDataDirExisting(io) catch |err| {
                if (err == error.FileNotFound) break :blk null;
                return err;
            };
            defer dir.close(io);
            break :blk versions.read(dir, io, ctx.allocator, id, digest) catch |err| {
                if (err == error.FileNotFound) break :blk null;
                return err;
            };
        };
        if (retained) |bytes| return bytes;
        const path = try self.contentPath(ctx, id);
        defer ctx.allocator.free(path);
        return std.Io.Dir.cwd().readFileAlloc(io, path, ctx.allocator, .limited(versions.max_encoded_bytes));
    }

    pub fn read(self: *Catalog, ctx: *RuntimeContext, id: u64) !@import("assets.zig").OwnedSource {
        const item = self.get(id) orelse return error.ResourceNotFound;
        var loaded = switch (item.kind) {
            .reference => try @import("assets.zig").readStandalone(ctx, item.source_uri),
            .owned => blk: {
                const bytes = try self.readOwnedBytes(ctx, id, item.content_hash);
                errdefer ctx.allocator.free(bytes);
                break :blk @import("assets.zig").OwnedSource{
                    .source = .{
                        .kind = .library,
                        .uri = &.{},
                        .identity = null,
                        .content_hash = hash(bytes),
                    },
                    .bytes = bytes,
                };
            },
        };
        errdefer loaded.deinit(ctx.allocator);
        if (!std.mem.eql(u8, &item.content_hash, &loaded.source.content_hash)) return error.ResourceContentChanged;
        const uri = try std.fmt.allocPrint(ctx.allocator, "library://{d}", .{id});
        ctx.allocator.free(loaded.source.uri);
        loaded.source.uri = uri;
        loaded.source.kind = .library;
        loaded.source.identity = .{ .library = id };
        return loaded;
    }

    /// Current complete file bytes for generic Resource consumers. Unlike the
    /// legacy Source reader this does not persist authorization observations.
    /// PNG decoding and media budgets belong to the eventual consumer.
    pub fn readFile(self: *Catalog, ctx: *RuntimeContext, id: u64) !@import("assets.zig").OwnedSource {
        const item = self.get(id) orelse return error.ResourceNotFound;
        if (item.kind == .owned) return self.read(ctx, id);
        const frozen = try ctx.external_sources.observeFile(ctx, item.source_uri);
        defer ctx.allocator.free(frozen.path);
        errdefer ctx.allocator.free(frozen.bytes);
        if (!std.mem.eql(u8, &item.content_hash, &frozen.digest)) return error.ResourceContentChanged;
        return .{
            .source = .{
                .kind = .library,
                .uri = try std.fmt.allocPrint(ctx.allocator, "library://{d}", .{id}),
                .identity = .{ .library = id },
                .content_hash = frozen.digest,
            },
            .bytes = frozen.bytes,
        };
    }

    /// Adoption pins the actual Station bytes, including a previously selected
    /// version whose Catalog head has since advanced. Browsing alone never pins.
    pub fn retainVersion(self: *Catalog, ctx: *RuntimeContext, id: u64, digest: [32]u8, bytes: []const u8) !void {
        _ = self.get(id) orelse return error.ResourceNotFound;
        try retainBytes(ctx, id, digest, bytes);
    }

    /// A bound Source resolves its own content version, never the latest head.
    /// Legacy unretained documents may read the current file only if the head
    /// and verified bytes still match. Corrupt retained bytes never fall back.
    pub fn readVersion(self: *Catalog, ctx: *RuntimeContext, id: u64, digest: [32]u8) !@import("assets.zig").OwnedSource {
        const item = self.get(id) orelse return error.ResourceNotFound;
        const io = ctx.io orelse return error.IoNotReady;
        const bytes: ?[]u8 = blk: {
            var dir = ctx.paths.openDataDirExisting(io) catch |err| {
                if (err == error.FileNotFound) break :blk null;
                return err;
            };
            defer dir.close(io);
            break :blk versions.read(dir, io, ctx.allocator, id, digest) catch |err| {
                if (err == error.FileNotFound) break :blk null;
                return err;
            };
        };
        if (bytes) |retained| {
            errdefer ctx.allocator.free(retained);
            return .{
                .source = .{
                    .kind = .library,
                    .uri = try std.fmt.allocPrint(ctx.allocator, "library://{d}", .{id}),
                    .identity = .{ .library = id },
                    .content_hash = digest,
                },
                .bytes = retained,
            };
        }
        if (!std.mem.eql(u8, &item.content_hash, &digest)) return error.ResourceVersionUnavailable;
        return self.read(ctx, id);
    }

    pub fn restore(self: *Catalog, ctx: *RuntimeContext) !void {
        const mutation = try self.prepareMutation(ctx, true);
        const io = ctx.io orelse return error.IoNotReady;
        const path = try ctx.paths.dataPath(ctx.allocator, catalog_path);
        defer ctx.allocator.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, ctx.allocator, .limited(128 * 1024)) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer ctx.allocator.free(text);
        const parsed = std.json.parseFromSlice(Manifest, ctx.allocator, text, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch return error.InvalidResourceLibrary;
        defer parsed.deinit();
        const manifest = parsed.value;
        const legacy = std.mem.eql(u8, manifest.format, "cutrans-resource-library/1");
        if ((!legacy and !std.mem.eql(u8, manifest.format, "cutrans-resource-library/2")) or manifest.next_id == 0 or manifest.resources.len > self.items.len or manifest.folders.len > self.folders.len) return error.InvalidResourceLibrary;
        // Reloading an older declaration within this Runtime must not reuse a
        // previously published stable library identity.
        var next: Catalog = .{ .next_id = @max(self.next_id, manifest.next_id) };
        errdefer next.deinit(ctx.allocator);
        for (manifest.folders) |entry| {
            if (legacy or entry.id == 0 or entry.id >= manifest.next_id or next.getNode(entry.id) != null) return error.InvalidResourceLibrary;
            try validLabel(entry.label);
            next.folders[next.folder_count] = .{
                .id = entry.id,
                .parent_id = entry.parent_id,
                .label = try ctx.allocator.dupe(u8, entry.label),
            };
            next.folder_count += 1;
        }
        for (manifest.resources) |entry| {
            if (entry.id == 0 or entry.id >= manifest.next_id) return error.InvalidResourceLibrary;
            try validLabel(entry.label);
            const kind = std.meta.stringToEnum(Kind, entry.kind) orelse return error.InvalidResourceLibrary;
            const provenance = std.meta.stringToEnum(Provenance, entry.provenance) orelse return error.InvalidResourceLibrary;
            if ((kind == .reference) != (provenance == .external)) return error.InvalidResourceLibrary;
            if (next.getNode(entry.id) != null or (legacy and entry.parent_id != 0)) return error.InvalidResourceLibrary;
            if (entry.sha256.len != 64) return error.InvalidResourceLibrary;
            var digest: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&digest, entry.sha256) catch return error.InvalidResourceLibrary;
            if (kind == .reference) {
                const uri = try externalUri(entry.source);
                if (!(ctx.mounts.isPersistentExternal(uri) catch return error.InvalidResourceLibrary)) return error.InvalidResourceLibrary;
            } else if (entry.source.len != 0) {
                // Detached data keeps its old virtual provenance even if the
                // grant is gone. Legacy created records may also carry it.
                // Host locators never belong in a public library declaration.
                _ = try externalUri(entry.source);
            }
            const label = try ctx.allocator.dupe(u8, entry.label);
            const source_uri = ctx.allocator.dupe(u8, entry.source) catch |err| {
                ctx.allocator.free(label);
                return err;
            };
            next.items[next.count] = .{
                .id = entry.id,
                .parent_id = entry.parent_id,
                .label = label,
                .kind = kind,
                .provenance = provenance,
                .source_uri = source_uri,
                .content_hash = digest,
            };
            next.count += 1;
        }
        next.validateHierarchy() catch return error.InvalidResourceLibrary;
        self.deinit(ctx.allocator);
        self.* = next;
        mutation.publish(self, ctx);
    }
};

fn onlyId(text: ?[]const u8) !u64 {
    const value = std.mem.trim(u8, text orelse return error.InvalidArguments, " \t");
    if (value.len == 0) return error.InvalidArguments;
    return std.fmt.parseInt(u64, value, 10) catch return error.InvalidArguments;
}

fn idAndLabel(text: ?[]const u8) !struct { id: u64, label: []const u8 } {
    const value = std.mem.trim(u8, text orelse return error.InvalidArguments, " \t");
    const split = std.mem.indexOfScalar(u8, value, ' ') orelse return error.InvalidArguments;
    const id = std.fmt.parseInt(u64, value[0..split], 10) catch return error.InvalidArguments;
    const label = std.mem.trim(u8, value[split + 1 ..], " \t");
    if (label.len == 0) return error.InvalidArguments;
    return .{ .id = id, .label = label };
}

pub fn dispatch(c: @import("command.zig").Command, opaque_ptr: *anyopaque) @import("command.zig").Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    if (std.mem.eql(u8, c.name, "library.folder.create")) {
        const parsed = idAndLabel(c.arg) catch return .failure(.invalid_arguments);
        const id = ctx.library.createFolder(ctx, parsed.id, parsed.label) catch |err| return switch (err) {
            error.InvalidResourceLabel => .failure(.invalid_arguments),
            error.InvalidResourceHierarchy => .failure(.invalid_state),
            else => .failure(.failed),
        };
        std.debug.print("CUTRANS_LIBRARY_FOLDER folder={d} parent={d}\n", .{ id, parsed.id });
        return .success;
    }
    if (std.mem.eql(u8, c.name, "library.rename")) {
        const parsed = idAndLabel(c.arg) catch return .failure(.invalid_arguments);
        ctx.library.rename(ctx, parsed.id, parsed.label) catch |err| return switch (err) {
            error.InvalidResourceLabel => .failure(.invalid_arguments),
            error.ResourceNotFound => .failure(.invalid_state),
            else => .failure(.failed),
        };
        std.debug.print("CUTRANS_LIBRARY_RENAME id={d}\n", .{parsed.id});
        return .success;
    }
    if (std.mem.eql(u8, c.name, "library.move")) {
        var parts = std.mem.tokenizeScalar(u8, c.arg orelse return .failure(.invalid_arguments), ' ');
        const id = std.fmt.parseInt(u64, parts.next() orelse return .failure(.invalid_arguments), 10) catch return .failure(.invalid_arguments);
        const parent = std.fmt.parseInt(u64, parts.next() orelse return .failure(.invalid_arguments), 10) catch return .failure(.invalid_arguments);
        if (parts.next() != null) return .failure(.invalid_arguments);
        ctx.library.move(ctx, id, parent) catch |err| return switch (err) {
            error.ResourceNotFound, error.InvalidResourceHierarchy => .failure(.invalid_state),
            else => .failure(.failed),
        };
        std.debug.print("CUTRANS_LIBRARY_MOVE id={d} parent={d}\n", .{ id, parent });
        return .success;
    }
    if (std.mem.eql(u8, c.name, "library.refresh")) {
        const id = onlyId(c.arg) catch return .failure(.invalid_arguments);
        const changed = ctx.library.refresh(ctx, id) catch |err| return switch (err) {
            error.ResourceNotFound, error.InvalidResourceState, error.ResourceContentChanged => .failure(.invalid_state),
            else => .failure(.failed),
        };
        std.debug.print("CUTRANS_LIBRARY_REFRESH library={d} changed={d}\n", .{ id, @intFromBool(changed) });
        return .success;
    }
    if (std.mem.eql(u8, c.name, "library.detach")) {
        const id = onlyId(c.arg) catch return .failure(.invalid_arguments);
        ctx.library.detach(ctx, id) catch |err| return switch (err) {
            error.ResourceNotFound, error.ResourceContentChanged => .failure(.invalid_state),
            else => .failure(.failed),
        };
        std.debug.print("CUTRANS_LIBRARY_DETACH library={d} id_preserved=1\n", .{id});
        return .success;
    }
    if (std.mem.eql(u8, c.name, "library.create")) {
        const value = std.mem.trim(u8, c.arg orelse return .failure(.invalid_arguments), " \t");
        const split = std.mem.indexOfScalar(u8, value, ' ') orelse return .failure(.invalid_arguments);
        const id = std.fmt.parseInt(u64, value[0..split], 10) catch return .failure(.invalid_arguments);
        const label = std.mem.trim(u8, value[split + 1 ..], " \t");
        if (label.len == 0) return .failure(.invalid_arguments);
        const asset = ctx.assets.get(id) catch return .failure(.invalid_state);
        const library_id = ctx.library.create(ctx, label, asset.bytes) catch return .failure(.failed);
        std.debug.print("CUTRANS_LIBRARY_CREATE library={d} source_asset={d}\n", .{ library_id, id });
        return .success;
    }
    if (std.mem.eql(u8, c.name, "library.list")) {
        for (ctx.library.folders[0..ctx.library.folder_count]) |folder| {
            std.debug.print("folder={d} parent={d} label={s}\n", .{ folder.id, folder.parent_id, folder.label });
        }
        for (ctx.library.items[0..ctx.library.count]) |item| {
            const digest = std.fmt.bytesToHex(item.content_hash, .lower);
            std.debug.print("library={d} parent={d} kind={s} provenance={s} label={s} sha256={s}\n", .{ item.id, item.parent_id, @tagName(item.kind), @tagName(item.provenance), item.label, &digest });
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

const LibraryCase = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    resource: []u8,
    data: []u8,
    catalog: []u8,
    source: []u8,

    fn init() !LibraryCase {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        errdefer allocator.free(root);
        const resource = try std.fs.path.join(allocator, &.{ root, "resources" });
        errdefer allocator.free(resource);
        const data = try std.fs.path.join(allocator, &.{ root, "data" });
        errdefer allocator.free(data);
        const catalog = try std.fs.path.join(allocator, &.{ data, catalog_path });
        errdefer allocator.free(catalog);
        const source = try std.fs.path.join(allocator, &.{ root, "source.png" });
        errdefer allocator.free(source);
        var pixels = [_]u8{ 10, 20, 30, 255 };
        try @import("image.zig").savePngExternal(allocator, std.testing.io, source, .{ .width = 1, .height = 1, .pixels = &pixels });
        return .{ .tmp = tmp, .root = root, .resource = resource, .data = data, .catalog = catalog, .source = source };
    }

    fn deinit(self: *LibraryCase) void {
        for ([_][]u8{ self.source, self.catalog, self.data, self.resource }) |path| std.testing.allocator.free(path);
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn open(self: *const LibraryCase, ctx: *RuntimeContext) !void {
        try fixture(ctx, self.resource, self.data);
    }

    fn png(self: *const LibraryCase, name: []const u8, color: u8) ![]u8 {
        const path = try std.fs.path.join(std.testing.allocator, &.{ self.root, name });
        errdefer std.testing.allocator.free(path);
        var pixels = [_]u8{ color, 20, 30, 255 };
        try @import("image.zig").savePngExternal(std.testing.allocator, std.testing.io, path, .{ .width = 1, .height = 1, .pixels = &pixels });
        return path;
    }

    fn catalogBytes(self: *const LibraryCase) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, self.catalog, std.testing.allocator, .limited(128 * 1024));
    }

    fn blockCatalog(self: *const LibraryCase) ![]u8 {
        const saved = try std.fs.path.join(std.testing.allocator, &.{ self.data, "library", "catalog.saved" });
        errdefer std.testing.allocator.free(saved);
        try std.Io.Dir.renameAbsolute(self.catalog, saved, std.testing.io);
        errdefer std.Io.Dir.renameAbsolute(saved, self.catalog, std.testing.io) catch {};
        try std.Io.Dir.createDirAbsolute(std.testing.io, self.catalog, .default_dir);
        return saved;
    }

    fn unblockCatalog(self: *const LibraryCase, saved: []const u8) !void {
        try std.Io.Dir.deleteDirAbsolute(std.testing.io, self.catalog);
        try std.Io.Dir.renameAbsolute(saved, self.catalog, std.testing.io);
    }
};

const TestFileLock = struct {
    file: std.Io.File,

    extern "kernel32" fn CreateFileW(name: [*:0]const u16, desired_access: u32, share_mode: u32, security_attributes: ?*anyopaque, creation_disposition: u32, flags_and_attributes: u32, template_file: ?*anyopaque) callconv(.winapi) ?*anyopaque;

    fn open(path: []const u8) !TestFileLock {
        if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
        var name = try std.Io.Threaded.sliceToPrefixedFileW(null, path, .{});
        name.data[0..4].* = .{ '\\', '\\', '?', '\\' };
        const handle = CreateFileW(name.span().ptr, 0x80000000, 0, null, 3, 0x80, null);
        if (handle == null or handle == @as(?*anyopaque, @ptrFromInt(std.math.maxInt(usize)))) return error.TestFileLockFailed;
        return .{ .file = .{ .handle = @ptrCast(handle.?), .flags = .{ .nonblocking = false } } };
    }

    fn close(self: *TestFileLock) void {
        self.file.close(std.testing.io);
        self.* = undefined;
    }
};

test "RAM detach survives a deleted original without touching authorization or Station leases" {
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const id = try ctx.library.importExternal(&ctx, tc.source);
    const handle = try ctx.assets.open(&ctx, "library://1");
    const selected = try ctx.assets.get(handle);
    const leases = selected.leases;
    const digest = selected.source.content_hash;
    const bytes = try std.testing.allocator.dupe(u8, selected.bytes);
    defer std.testing.allocator.free(bytes);
    const folder = try ctx.library.createFolder(&ctx, 0, "photos");
    try ctx.library.move(&ctx, id, folder);
    try ctx.library.rename(&ctx, id, "photograph.png");
    const revision = ctx.library.revision;
    const assets_revision = ctx.assets.revision;
    const auth_path = try ctx.paths.dataPath(std.testing.allocator, external_sources.catalog_path);
    defer std.testing.allocator.free(auth_path);
    const original_auth = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, auth_path, std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(original_auth);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, tc.source);
    {
        var authorization_lock = try TestFileLock.open(auth_path);
        defer authorization_lock.close();
        try ctx.library.detach(&ctx, id);
    }
    const item = ctx.library.get(id).?;
    try std.testing.expectEqual(Kind.owned, item.kind);
    try std.testing.expectEqual(Provenance.detached, item.provenance);
    try std.testing.expectEqualStrings("photograph.png", item.label);
    try std.testing.expectEqual(folder, item.parent_id);
    try std.testing.expectEqualStrings("external://1", item.source_uri);
    try std.testing.expectEqual(digest, item.content_hash);
    try std.testing.expectEqual(@as(usize, 1), ctx.library.count);
    try std.testing.expectEqual(revision + 1, ctx.library.revision);
    try std.testing.expectEqual(assets_revision + 1, ctx.assets.revision);
    try std.testing.expectEqual(@as(usize, 1), ctx.assets.count);
    try std.testing.expectEqual(leases, (try ctx.assets.get(handle)).leases);
    try std.testing.expectEqualSlices(u8, bytes, (try ctx.assets.get(handle)).bytes);
    const unchanged_auth = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, auth_path, std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(unchanged_auth);
    try std.testing.expectEqualSlices(u8, original_auth, unchanged_auth);

    var restored: RuntimeContext = undefined;
    try tc.open(&restored);
    defer restored.deinit();
    try restored.external_sources.restore(&restored);
    try restored.library.restore(&restored);
    var owned = try restored.library.read(&restored, id);
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, bytes, owned.bytes);
    try std.testing.expectEqualStrings("photograph.png", restored.library.get(id).?.label);
    try std.testing.expectEqual(folder, restored.library.get(id).?.parent_id);
}

test "detach never substitutes old Station bytes for a newer library head" {
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const id = try ctx.library.importExternal(&ctx, tc.source);
    const handle = try ctx.assets.open(&ctx, "library://1");
    const old_hash = (try ctx.assets.get(handle)).source.content_hash;
    const newer_path = try tc.png("newer.png", 99);
    defer std.testing.allocator.free(newer_path);
    const newer = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, newer_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(newer);
    // Keep the authorization object, advancing only its content in place.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tc.source, .data = newer });
    try std.testing.expect(try ctx.library.refresh(&ctx, id));
    const current_hash = ctx.library.get(id).?.content_hash;
    try std.testing.expect(!std.mem.eql(u8, &old_hash, &current_hash));
    try std.testing.expect(ctx.assets.findResourceHead(id, current_hash) == null);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, tc.source);
    const revision = ctx.library.revision;
    const assets_revision = ctx.assets.revision;
    try std.testing.expectError(error.FileNotFound, ctx.library.detach(&ctx, id));
    try std.testing.expectEqual(Kind.reference, ctx.library.get(id).?.kind);
    try std.testing.expectEqual(current_hash, ctx.library.get(id).?.content_hash);
    try std.testing.expectEqual(revision, ctx.library.revision);
    try std.testing.expectEqual(assets_revision, ctx.assets.revision);
    try std.testing.expectEqual(@as(usize, 1), ctx.assets.count);
    try std.testing.expectEqual(old_hash, (try ctx.assets.get(handle)).source.content_hash);
}

test "RAM detach lock failures and corrupt versions never publish or repair owned state" {
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const id = try ctx.library.importExternal(&ctx, tc.source);
    const handle = try ctx.assets.open(&ctx, "library://1");
    const resident = try ctx.assets.get(handle);
    const digest = resident.source.content_hash;
    const bytes = try std.testing.allocator.dupe(u8, resident.bytes);
    defer std.testing.allocator.free(bytes);
    const leases = resident.leases;
    try ctx.library.retainVersion(&ctx, id, digest, bytes);
    const relative = try versions.relativePath(std.testing.allocator, id, digest);
    defer std.testing.allocator.free(relative);
    const retained_path = try ctx.paths.dataPath(std.testing.allocator, relative);
    defer std.testing.allocator.free(retained_path);
    const revision = ctx.library.revision;
    const assets_revision = ctx.assets.revision;
    const catalog = try tc.catalogBytes();
    defer std.testing.allocator.free(catalog);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, tc.source);
    {
        var version_lock = try TestFileLock.open(retained_path);
        defer version_lock.close();
        if (ctx.library.detach(&ctx, id)) |_| return error.TestExpectedError else |_| {}
    }
    try std.testing.expectEqual(Kind.reference, ctx.library.get(id).?.kind);
    try std.testing.expectEqual(revision, ctx.library.revision);
    try std.testing.expectEqual(assets_revision, ctx.assets.revision);
    {
        var catalog_lock = try TestFileLock.open(tc.catalog);
        defer catalog_lock.close();
        if (ctx.library.detach(&ctx, id)) |_| return error.TestExpectedError else |_| {}
    }
    try std.testing.expectEqual(Kind.reference, ctx.library.get(id).?.kind);
    try std.testing.expectEqual(Provenance.external, ctx.library.get(id).?.provenance);
    try std.testing.expectEqual(revision, ctx.library.revision);
    try std.testing.expectEqual(assets_revision, ctx.assets.revision);
    try std.testing.expectEqual(leases, (try ctx.assets.get(handle)).leases);
    try std.testing.expectEqualSlices(u8, bytes, (try ctx.assets.get(handle)).bytes);
    const after = try tc.catalogBytes();
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, catalog, after);
    const retained = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, retained_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualSlices(u8, bytes, retained);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = retained_path, .data = "damaged immutable version" });
    try std.testing.expectError(error.ResourceVersionContentMismatch, ctx.library.detach(&ctx, id));
    const damaged = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, retained_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(damaged);
    try std.testing.expectEqualStrings("damaged immutable version", damaged);
    try std.testing.expectEqual(Kind.reference, ctx.library.get(id).?.kind);
    try std.testing.expectEqual(revision, ctx.library.revision);
    try std.testing.expectEqual(assets_revision, ctx.assets.revision);
    try std.testing.expectEqual(leases, (try ctx.assets.get(handle)).leases);
}

test "owned publication failures preserve old content files and immutable dependencies" {
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, tc.source, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    const old_content = try ctx.library.contentPath(&ctx, 1);
    defer std.testing.allocator.free(old_content);
    try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, old_content, "pre-existing evidence");
    try std.testing.expectError(error.InvalidResourceLabel, ctx.library.create(&ctx, "../invalid", bytes));
    try std.Io.Dir.cwd().createDirPath(std.testing.io, tc.catalog);
    if (ctx.library.create(&ctx, "owned.png", bytes)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expectEqual(@as(usize, 0), ctx.library.count);
    try std.testing.expectEqual(@as(u64, 1), ctx.library.next_id);
    try std.testing.expectEqual(@as(u64, 0), ctx.library.revision);
    try std.testing.expectEqual(@as(u64, 0), ctx.assets.revision);
    const evidence = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, old_content, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(evidence);
    try std.testing.expectEqualStrings("pre-existing evidence", evidence);
    var dir = try ctx.paths.openDataDirExisting(std.testing.io);
    defer dir.close(std.testing.io);
    const orphan = try versions.read(dir, std.testing.io, std.testing.allocator, 1, hash(bytes));
    defer std.testing.allocator.free(orphan);
    try std.testing.expectEqualSlices(u8, bytes, orphan);
    try std.Io.Dir.deleteDirAbsolute(std.testing.io, tc.catalog);
    try std.testing.expectEqual(@as(u64, 1), try ctx.library.create(&ctx, "owned.png", bytes));
    var owned = try ctx.library.read(&ctx, 1);
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, bytes, owned.bytes);

    const id = try ctx.library.importExternal(&ctx, tc.source);
    const detached_legacy = try ctx.library.contentPath(&ctx, id);
    defer std.testing.allocator.free(detached_legacy);
    try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, detached_legacy, "detach evidence");
    const revision = ctx.library.revision;
    const saved = try tc.blockCatalog();
    defer std.testing.allocator.free(saved);
    if (ctx.library.detach(&ctx, id)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expectEqual(Kind.reference, ctx.library.get(id).?.kind);
    try std.testing.expectEqual(Provenance.external, ctx.library.get(id).?.provenance);
    try std.testing.expectEqual(revision, ctx.library.revision);
    const preserved = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, detached_legacy, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings("detach evidence", preserved);
    try tc.unblockCatalog(saved);
    try ctx.library.detach(&ctx, id);
    try std.testing.expectEqual(revision + 1, ctx.library.revision);
    try ctx.library.detach(&ctx, id);
    try std.testing.expectEqual(revision + 1, ctx.library.revision);
}

test "owned legacy fallback never masks a corrupt retained version" {
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, tc.source, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    const id = try ctx.library.append(&ctx, "legacy.png", .owned, .created, "", hash(bytes), 0);
    const path = try ctx.library.contentPath(&ctx, id);
    defer std.testing.allocator.free(path);
    try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, path, bytes);
    var legacy = try ctx.library.read(&ctx, id);
    defer legacy.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, bytes, legacy.bytes);
    try ctx.library.retainVersion(&ctx, id, hash(bytes), bytes);
    const relative = try versions.relativePath(std.testing.allocator, id, hash(bytes));
    defer std.testing.allocator.free(relative);
    const retained = try ctx.paths.dataPath(std.testing.allocator, relative);
    defer std.testing.allocator.free(retained);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = retained, .data = "corrupt" });
    try std.testing.expectError(error.ResourceVersionContentMismatch, ctx.library.read(&ctx, id));
    try std.testing.expectError(error.ResourceVersionContentMismatch, ctx.library.readVersion(&ctx, id, hash(bytes)));
}

test "resource mutation revisions are exact and overflow rejects before IO" {
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const id = try ctx.library.importExternal(&ctx, tc.source);
    try std.testing.expectEqual(@as(u64, 1), ctx.library.revision);
    const folder = try ctx.library.createFolder(&ctx, 0, "folder");
    try ctx.library.rename(&ctx, id, "renamed.png");
    try ctx.library.move(&ctx, id, folder);
    try std.testing.expectEqual(@as(u64, 4), ctx.library.revision);
    try ctx.library.rename(&ctx, id, "renamed.png");
    try ctx.library.move(&ctx, id, folder);
    try std.testing.expect(!try ctx.library.refresh(&ctx, id));
    try std.testing.expectEqual(id, try ctx.library.importExternal(&ctx, tc.source));
    try std.testing.expectEqual(@as(u64, 4), ctx.library.revision);
    try ctx.library.restore(&ctx);
    try std.testing.expectEqual(@as(u64, 5), ctx.library.revision);
    const initial = try tc.catalogBytes();
    defer std.testing.allocator.free(initial);
    var frozen = try external_sources.readFrozen(&ctx, tc.source);
    defer frozen.deinit(std.testing.allocator);
    ctx.library.revision = std.math.maxInt(u64);
    ctx.io = null;
    try std.testing.expectError(error.ResourceRevisionExhausted, ctx.library.create(&ctx, "new.png", frozen.bytes));
    try std.testing.expectError(error.ResourceRevisionExhausted, ctx.library.createFolder(&ctx, 0, "new"));
    try std.testing.expectError(error.ResourceRevisionExhausted, ctx.library.rename(&ctx, id, "new.png"));
    try std.testing.expectError(error.ResourceRevisionExhausted, ctx.library.move(&ctx, id, 0));
    try std.testing.expectError(error.ResourceRevisionExhausted, ctx.library.refresh(&ctx, id));
    try std.testing.expectError(error.ResourceRevisionExhausted, ctx.library.detach(&ctx, id));
    try std.testing.expectError(error.ResourceRevisionExhausted, ctx.library.importExternal(&ctx, tc.source));
    try std.testing.expectError(error.ResourceRevisionExhausted, ctx.library.rebind(&ctx, id, .adopt, &frozen));
    try std.testing.expectError(error.ResourceRevisionExhausted, ctx.library.restore(&ctx));
    try ctx.library.rename(&ctx, id, "renamed.png");
    try ctx.library.move(&ctx, id, folder);
    ctx.library.revision = 5;
    ctx.library.next_id = std.math.maxInt(u64);
    try std.testing.expectError(error.ResourceIdExhausted, ctx.library.create(&ctx, "new.png", frozen.bytes));
    try std.testing.expectError(error.ResourceIdExhausted, ctx.library.createFolder(&ctx, 0, "new"));
    try std.testing.expectError(error.ResourceIdExhausted, ctx.library.importExternal(&ctx, tc.source));
    ctx.library.next_id = folder + 1;
    ctx.assets.revision = std.math.maxInt(u64);
    try std.testing.expectError(error.AssetRevisionExhausted, ctx.library.create(&ctx, "new.png", frozen.bytes));
    try std.testing.expectError(error.AssetRevisionExhausted, ctx.library.detach(&ctx, id));
    ctx.io = std.testing.io;
    const after = try tc.catalogBytes();
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(initial, after);
    try std.testing.expectEqual(@as(u64, 5), ctx.library.revision);
}

test "same Runtime restore keeps the highest issued resource identity" {
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const first = try ctx.library.createFolder(&ctx, 0, "first");
    const older = try tc.catalogBytes();
    defer std.testing.allocator.free(older);
    const second = try ctx.library.createFolder(&ctx, 0, "second");
    try std.testing.expectEqual(first + 1, second);
    const high_water = ctx.library.next_id;
    const revision = ctx.library.revision;
    try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, tc.catalog, older);
    try ctx.library.restore(&ctx);
    try std.testing.expectEqual(high_water, ctx.library.next_id);
    try std.testing.expectEqual(revision + 1, ctx.library.revision);
    try std.testing.expect(ctx.library.getFolder(second) == null);
    const replacement = try ctx.library.createFolder(&ctx, 0, "replacement");
    try std.testing.expectEqual(high_water, replacement);
    try std.testing.expect(replacement > second);
    var reopened: RuntimeContext = undefined;
    try tc.open(&reopened);
    defer reopened.deinit();
    try reopened.library.restore(&reopened);
    try std.testing.expectEqual(replacement + 1, reopened.library.next_id);
    try std.testing.expect(reopened.library.getFolder(replacement) != null);
}

test "same Runtime restore invalidates Station ownership projections before IO overflow" {
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const id = try ctx.library.importExternal(&ctx, tc.source);
    const handle = try ctx.assets.open(&ctx, "library://1");
    const reference = try tc.catalogBytes();
    defer std.testing.allocator.free(reference);
    try ctx.library.detach(&ctx, id);
    try std.testing.expectEqual(Kind.owned, ctx.library.get(id).?.kind);
    const revision = ctx.library.revision;
    const assets_revision = ctx.assets.revision;
    const station_count = ctx.assets.count;
    try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, tc.catalog, reference);
    try ctx.library.restore(&ctx);
    try std.testing.expectEqual(Kind.reference, ctx.library.get(id).?.kind);
    try std.testing.expectEqual(revision + 1, ctx.library.revision);
    try std.testing.expectEqual(assets_revision + 1, ctx.assets.revision);
    try std.testing.expectEqual(station_count, ctx.assets.count);
    const selected = try ctx.assets.get(handle);
    try std.testing.expectEqual(id, selected.source.identity.?.library);
    ctx.assets.revision = std.math.maxInt(u64);
    ctx.io = null;
    try std.testing.expectError(error.AssetRevisionExhausted, ctx.library.restore(&ctx));
    try std.testing.expectEqual(revision + 1, ctx.library.revision);
    try std.testing.expectEqual(station_count, ctx.assets.count);
    ctx.io = std.testing.io;
}

test "owned restore rejects physical locators without rewriting evidence" {
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const zero_hash = "0000000000000000000000000000000000000000000000000000000000000000";
    for ([_][]const u8{ "created", "detached" }) |provenance| {
        for ([_][]const u8{ "C:/private/synthetic.png", "session://private.png", "external://0", "external://+1", "external://1_0" }) |source| {
            const text = try std.fmt.allocPrint(std.testing.allocator, "{{\"format\":\"cutrans-resource-library/2\",\"next_id\":2,\"resources\":[{{\"id\":1,\"label\":\"owned.png\",\"kind\":\"owned\",\"provenance\":\"{s}\",\"source\":{f},\"sha256\":\"{s}\"}}]}}\n", .{ provenance, std.json.fmt(source, .{}), zero_hash });
            defer std.testing.allocator.free(text);
            try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, tc.catalog, text);
            try std.testing.expectError(error.InvalidResourceLibrary, ctx.library.restore(&ctx));
            try std.testing.expectEqual(@as(usize, 0), ctx.library.count);
            try std.testing.expectEqual(@as(u64, 0), ctx.library.revision);
            const unchanged = try tc.catalogBytes();
            defer std.testing.allocator.free(unchanged);
            try std.testing.expectEqualStrings(text, unchanged);
        }
    }
    const legacy = "{\"format\":\"cutrans-resource-library/1\",\"next_id\":3,\"resources\":[" ++
        "{\"id\":1,\"label\":\"detached.png\",\"kind\":\"owned\",\"provenance\":\"detached\",\"source\":\"external://999\",\"sha256\":\"" ++ zero_hash ++ "\"}," ++
        "{\"id\":2,\"label\":\"created.png\",\"kind\":\"owned\",\"provenance\":\"created\",\"source\":\"external://1000\",\"sha256\":\"" ++ zero_hash ++ "\"}]}\n";
    try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, tc.catalog, legacy);
    try ctx.library.restore(&ctx);
    try std.testing.expectEqual(@as(usize, 2), ctx.library.count);
    try std.testing.expectEqualStrings("external://999", ctx.library.get(1).?.source_uri);
    try std.testing.expectEqualStrings("external://1000", ctx.library.get(2).?.source_uri);
    try std.testing.expect(!try ctx.mounts.isPersistentExternal(try @import("vne").uri.parse("external://999")));
    const unchanged = try tc.catalogBytes();
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings(legacy, unchanged);
}

test "relocate and adopt preserve resource identity and previously selected bytes" {
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const id = try ctx.library.importExternal(&ctx, tc.source);
    const old_hash = ctx.library.get(id).?.content_hash;
    const station = try ctx.assets.open(&ctx, "library://1");
    const old_count = ctx.assets.count;
    const document_revision = ctx.document_revision;
    const moved = try tc.png("moved.png", 10);
    defer std.testing.allocator.free(moved);
    var selected = try external_sources.readFrozen(&ctx, moved);
    defer selected.deinit(std.testing.allocator);
    try validateCandidate(std.testing.allocator, selected.bytes);
    try ctx.library.rebind(&ctx, id, .relocate, &selected);
    try std.testing.expectEqual(@as(u64, 2), ctx.library.revision);
    try std.testing.expectEqual(@as(usize, 2), ctx.external_sources.count);
    try std.testing.expectEqualStrings("external://2", ctx.library.get(id).?.source_uri);
    try std.testing.expectEqual(Kind.reference, ctx.library.get(id).?.kind);
    try std.testing.expectEqual(Provenance.external, ctx.library.get(id).?.provenance);
    try std.testing.expectEqual(old_hash, ctx.library.get(id).?.content_hash);
    try ctx.library.rebind(&ctx, id, .relocate, &selected);
    try std.testing.expectEqual(@as(u64, 2), ctx.library.revision);
    try std.testing.expectEqual(@as(usize, 2), ctx.external_sources.count);
    // A different object at the same locator gets a different immutable grant.
    const changed = try tc.png("moved.png", 99);
    defer std.testing.allocator.free(changed);
    var newer = try external_sources.readFrozen(&ctx, moved);
    defer newer.deinit(std.testing.allocator);
    try std.testing.expectError(error.ResourceContentChanged, ctx.library.rebind(&ctx, id, .relocate, &newer));
    try std.testing.expectEqual(@as(u64, 2), ctx.library.revision);
    try std.testing.expectEqual(@as(usize, 2), ctx.external_sources.count);
    try ctx.library.rebind(&ctx, id, .adopt, &newer);
    try std.testing.expectEqual(@as(u64, 3), ctx.library.revision);
    try std.testing.expectEqual(@as(usize, 3), ctx.external_sources.count);
    try std.testing.expectEqualStrings("external://3", ctx.library.get(id).?.source_uri);
    try std.testing.expectEqual(newer.digest, ctx.library.get(id).?.content_hash);
    try std.testing.expectEqual(document_revision, ctx.document_revision);
    try std.testing.expectEqual(old_count, ctx.assets.count);
    const existing = try ctx.assets.get(station);
    try std.testing.expectEqual(old_hash, existing.source.content_hash);
    try std.testing.expectEqualSlices(u8, selected.bytes, existing.bytes);
    var old_version = try ctx.library.readVersion(&ctx, id, old_hash);
    defer old_version.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, selected.bytes, old_version.bytes);
    var current = try ctx.library.read(&ctx, id);
    defer current.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, newer.bytes, current.bytes);
    try std.testing.expectError(error.SourceIdentityChanged, @import("assets.zig").readStandalone(&ctx, "external://2"));
    var restored: RuntimeContext = undefined;
    try tc.open(&restored);
    defer restored.deinit();
    try restored.external_sources.restore(&restored);
    try restored.library.restore(&restored);
    try std.testing.expectEqual(id, restored.library.get(id).?.id);
    try std.testing.expectEqualStrings("external://3", restored.library.get(id).?.source_uri);
    var restored_old = try restored.library.readVersion(&restored, id, old_hash);
    defer restored_old.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, selected.bytes, restored_old.bytes);
    var restored_new = try restored.library.read(&restored, id);
    defer restored_new.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, newer.bytes, restored_new.bytes);
}

test "failed rebind preserves the visible head while explicit dependencies remain explainable" {
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const id = try ctx.library.importExternal(&ctx, tc.source);
    const original = try tc.catalogBytes();
    defer std.testing.allocator.free(original);
    const original_hash = ctx.library.get(id).?.content_hash;
    const changed = try tc.png("changed.png", 88);
    defer std.testing.allocator.free(changed);
    var candidate = try external_sources.readFrozen(&ctx, changed);
    defer candidate.deinit(std.testing.allocator);
    const versions_path = try ctx.paths.dataPath(std.testing.allocator, "library/versions");
    defer std.testing.allocator.free(versions_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = versions_path, .data = "retention blocker" });
    if (ctx.library.rebind(&ctx, id, .adopt, &candidate)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expectEqual(@as(u64, 1), ctx.library.revision);
    try std.testing.expectEqual(@as(usize, 1), ctx.external_sources.count);
    try std.testing.expectEqual(original_hash, ctx.library.get(id).?.content_hash);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, versions_path);
    const saved = try tc.blockCatalog();
    defer std.testing.allocator.free(saved);
    if (ctx.library.rebind(&ctx, id, .adopt, &candidate)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expectEqual(@as(u64, 1), ctx.library.revision);
    try std.testing.expectEqualStrings("external://1", ctx.library.get(id).?.source_uri);
    try std.testing.expectEqual(original_hash, ctx.library.get(id).?.content_hash);
    // Authorization and retained bytes committed first; neither is rolled
    // back or silently deleted to pretend both catalogs were one transaction.
    try std.testing.expectEqual(@as(usize, 2), ctx.external_sources.count);
    var dir = try ctx.paths.openDataDirExisting(std.testing.io);
    defer dir.close(std.testing.io);
    const retained = try versions.read(dir, std.testing.io, std.testing.allocator, id, candidate.digest);
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualSlices(u8, candidate.bytes, retained);
    try tc.unblockCatalog(saved);
    const after = try tc.catalogBytes();
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(original, after);
    var restored: RuntimeContext = undefined;
    try tc.open(&restored);
    defer restored.deinit();
    try restored.external_sources.restore(&restored);
    try restored.library.restore(&restored);
    try std.testing.expectEqualStrings("external://1", restored.library.get(id).?.source_uri);
    try std.testing.expectEqual(@as(usize, 2), restored.external_sources.count);
    try ctx.library.rebind(&ctx, id, .adopt, &candidate);
    try std.testing.expectEqual(@as(u64, 2), ctx.library.revision);
    try std.testing.expectEqual(@as(usize, 2), ctx.external_sources.count);
    try std.testing.expectEqual(candidate.digest, ctx.library.get(id).?.content_hash);
    try ctx.library.detach(&ctx, id);
    try std.testing.expectError(error.InvalidResourceState, ctx.library.rebind(&ctx, id, .adopt, &candidate));
}

test "candidate PNG bounds run before actual decode and reject invalid encoded images" {
    var header: [33]u8 = @splat(0);
    @memcpy(header[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, header[8..12], 13, .big);
    @memcpy(header[12..16], "IHDR");
    std.mem.writeInt(u32, header[16..20], 4097, .big);
    std.mem.writeInt(u32, header[20..24], 4096, .big);
    try std.testing.expectError(error.ExportDecodedBudgetExceeded, validateCandidate(std.testing.allocator, &header));
    std.mem.writeInt(u32, header[16..20], 1, .big);
    std.mem.writeInt(u32, header[20..24], 1, .big);
    try std.testing.expectError(error.ImageDecodeFailed, validateCandidate(std.testing.allocator, &header));
}

test "library detach preserves identity and restores owned content without the external file" {
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
    var pixels = [_]u8{ 1, 2, 3, 255 };
    try @import("image.zig").savePngExternal(std.testing.allocator, std.testing.io, source, .{ .width = 1, .height = 1, .pixels = &pixels });
    var ctx: RuntimeContext = undefined;
    try fixture(&ctx, resource, data);
    defer ctx.deinit();
    const id = try ctx.library.importExternal(&ctx, source);
    try std.testing.expectEqual(@as(u64, 1), id);
    const first = try ctx.assets.open(&ctx, "library://1");
    _ = try ctx.assets.preview(first);
    try ctx.library.detach(&ctx, id);
    try std.testing.expectEqual(Kind.owned, ctx.library.get(id).?.kind);
    try std.testing.expectEqual(Provenance.detached, ctx.library.get(id).?.provenance);
    const second = try ctx.assets.open(&ctx, "library://1");
    try std.testing.expectEqual(first, second);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, source);
    _ = try ctx.assets.preview(second);

    var restored: RuntimeContext = undefined;
    try fixture(&restored, resource, data);
    defer restored.deinit();
    try restored.external_sources.restore(&restored);
    try restored.library.restore(&restored);
    const reopened = try restored.assets.open(&restored, "library://1");
    _ = try restored.assets.preview(reopened);
    try std.testing.expectEqual(Kind.owned, restored.library.get(id).?.kind);
}

test "library refresh is explicit and owned content is hash checked" {
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
    var pixels = [_]u8{ 1, 2, 3, 255 };
    try @import("image.zig").savePngExternal(std.testing.allocator, std.testing.io, source, .{ .width = 1, .height = 1, .pixels = &pixels });
    var ctx: RuntimeContext = undefined;
    try fixture(&ctx, resource, data);
    defer ctx.deinit();
    const id = try ctx.library.importExternal(&ctx, source);
    pixels[0] = 9;
    // Exercise an in-place content edit. Atomic image replacement deliberately
    // changes file identity and is rejected before this content-refresh policy.
    try @import("image.zig").savePng(std.testing.allocator, std.testing.io, tmp.dir, "changed.png", .{ .width = 1, .height = 1, .pixels = &pixels });
    const changed = try tmp.dir.readFileAlloc(std.testing.io, "changed.png", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(changed);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = source, .data = changed });
    try std.testing.expectError(error.ResourceContentChanged, ctx.library.read(&ctx, id));
    try std.testing.expect(try ctx.library.refresh(&ctx, id));
    try ctx.library.detach(&ctx, id);
    const retained_relative = try versions.relativePath(std.testing.allocator, id, ctx.library.get(id).?.content_hash);
    defer std.testing.allocator.free(retained_relative);
    const content_path = try ctx.paths.dataPath(std.testing.allocator, retained_relative);
    defer std.testing.allocator.free(content_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = content_path, .data = "tampered" });
    try std.testing.expectError(error.ResourceVersionContentMismatch, ctx.library.read(&ctx, id));
    const catalog_file = try std.fs.path.join(std.testing.allocator, &.{ data, catalog_path });
    defer std.testing.allocator.free(catalog_file);
    try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, catalog_file, "not-json");
    var corrupted: RuntimeContext = undefined;
    try fixture(&corrupted, resource, data);
    defer corrupted.deinit();
    try std.testing.expectError(error.InvalidResourceLibrary, corrupted.library.restore(&corrupted));
    pixels[1] = 42;
    try @import("image.zig").savePng(std.testing.allocator, std.testing.io, tmp.dir, "created.png", .{ .width = 1, .height = 1, .pixels = &pixels });
    const created_bytes = try tmp.dir.readFileAlloc(std.testing.io, "created.png", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(created_bytes);
    const created = try corrupted.library.create(&corrupted, "created.png", created_bytes);
    try std.testing.expectEqual(Kind.owned, corrupted.library.get(created).?.kind);
    try std.testing.expectEqual(Provenance.created, corrupted.library.get(created).?.provenance);
    const created_asset = try corrupted.assets.open(&corrupted, "library://1");
    _ = try corrupted.assets.preview(created_asset);
}

test "library folders persist logical hierarchy without changing resource identity" {
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
    var pixels = [_]u8{ 1, 2, 3, 255 };
    try @import("image.zig").savePngExternal(std.testing.allocator, std.testing.io, source, .{ .width = 1, .height = 1, .pixels = &pixels });
    var ctx: RuntimeContext = undefined;
    try fixture(&ctx, resource, data);
    defer ctx.deinit();
    const resource_id = try ctx.library.importExternal(&ctx, source);
    const original_hash = ctx.library.get(resource_id).?.content_hash;
    const folder = try ctx.library.createFolder(&ctx, 0, "素材");
    const child = try ctx.library.createFolder(&ctx, folder, "角色");
    try std.testing.expectEqual(@as(u64, 2), folder);
    try std.testing.expectEqual(@as(u64, 3), child);
    try ctx.library.move(&ctx, resource_id, child);
    try ctx.library.rename(&ctx, resource_id, "renamed.png");
    try ctx.library.rename(&ctx, child, "主角");
    try std.testing.expectError(error.InvalidResourceHierarchy, ctx.library.move(&ctx, folder, child));
    try std.testing.expectError(error.InvalidResourceHierarchy, ctx.library.move(&ctx, resource_id, 99));
    try ctx.library.detach(&ctx, resource_id);

    var restored: RuntimeContext = undefined;
    try fixture(&restored, resource, data);
    defer restored.deinit();
    try restored.library.restore(&restored);
    try std.testing.expectEqual(@as(usize, 2), restored.library.folder_count);
    try std.testing.expectEqualStrings("主角", restored.library.getFolder(child).?.label);
    try std.testing.expectEqual(folder, restored.library.getFolder(child).?.parent_id);
    try std.testing.expectEqual(child, restored.library.get(resource_id).?.parent_id);
    try std.testing.expectEqualStrings("renamed.png", restored.library.get(resource_id).?.label);
    try std.testing.expectEqual(original_hash, restored.library.get(resource_id).?.content_hash);
    const reopened = try restored.assets.open(&restored, "library://1");
    _ = try restored.assets.preview(reopened);

    const legacy_data = try std.fs.path.join(std.testing.allocator, &.{ root, "legacy data" });
    defer std.testing.allocator.free(legacy_data);
    const legacy_path = try std.fs.path.join(std.testing.allocator, &.{ legacy_data, catalog_path });
    defer std.testing.allocator.free(legacy_path);
    try storage.writeAtomic(std.Io.Dir.cwd(), std.testing.io, legacy_path, "{\"format\":\"cutrans-resource-library/1\",\"next_id\":2,\"resources\":[{\"id\":1,\"label\":\"legacy.png\",\"kind\":\"owned\",\"provenance\":\"created\",\"source\":\"\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}]}\n");
    var legacy: RuntimeContext = undefined;
    try fixture(&legacy, resource, legacy_data);
    defer legacy.deinit();
    try legacy.library.restore(&legacy);
    try std.testing.expectEqual(@as(usize, 0), legacy.library.folder_count);
    try std.testing.expectEqual(@as(u64, 0), legacy.library.get(1).?.parent_id);
}

test "generic registration and file reads preserve TXT opaque empty and PNG bytes without decoding" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const allocator = std.testing.allocator;
    const cases = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "note.txt", .bytes = "plain text / 中文\n" },
        .{ .name = "another-note.txt", .bytes = "plain text / 中文\n" },
        .{ .name = "unknown.weird", .bytes = "\x00\xff\x01opaque\x00bytes" },
        .{ .name = "empty.dat", .bytes = "" },
    };
    var first_text_id: ?u64 = null;
    for (cases) |case| {
        const path = try std.fs.path.join(allocator, &.{ tc.root, case.name });
        defer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = case.bytes });
        const id = try ctx.library.registerFile(&ctx, path);
        if (std.mem.eql(u8, case.bytes, cases[0].bytes)) {
            if (first_text_id) |previous| try std.testing.expect(previous != id) else first_text_id = id;
        }
        const item = ctx.library.get(id).?;
        try std.testing.expectEqualStrings(case.name, item.label);
        try std.testing.expectEqual(Kind.reference, item.kind);
        try std.testing.expectEqual(hash(case.bytes), item.content_hash);
        const revision = ctx.library.revision;
        const catalog = try tc.catalogBytes();
        defer allocator.free(catalog);
        const auth_path = try ctx.paths.dataPath(allocator, external_sources.catalog_path);
        defer allocator.free(auth_path);
        const authorization = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, auth_path, allocator, .limited(256 * 1024));
        defer allocator.free(authorization);
        var read = try ctx.library.readFile(&ctx, id);
        defer read.deinit(allocator);
        try std.testing.expectEqualSlices(u8, case.bytes, read.bytes);
        try std.testing.expectEqual(id, read.source.identity.?.library);
        try std.testing.expectEqual(revision, ctx.library.revision);
        const after_catalog = try tc.catalogBytes();
        defer allocator.free(after_catalog);
        const after_authorization = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, auth_path, allocator, .limited(256 * 1024));
        defer allocator.free(after_authorization);
        try std.testing.expectEqualSlices(u8, catalog, after_catalog);
        try std.testing.expectEqualSlices(u8, authorization, after_authorization);
    }
    const png_id = try ctx.library.registerFile(&ctx, tc.source);
    var png = try ctx.library.readFile(&ctx, png_id);
    defer png.deinit(allocator);
    try validateCandidate(allocator, png.bytes);
    try std.testing.expectEqual(@as(usize, 5), ctx.library.count);
    try std.testing.expectEqual(@as(usize, 0), ctx.assets.count);
}

test "generic registration reuses existing identity at capacity and rejects drift or invalid snapshots" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    const allocator = std.testing.allocator;
    const id = try ctx.library.registerFile(&ctx, tc.source);
    var frozen = try external_sources.readFileSnapshot(&ctx, tc.source);
    defer frozen.deinit(allocator);
    while (ctx.library.count < ctx.library.items.len) {
        var name_buffer: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&name_buffer, "padding-{d}.bin", .{ctx.library.count});
        _ = try ctx.library.create(&ctx, label, "padding");
    }
    const saved_next_id = ctx.library.next_id;
    ctx.library.next_id = 0;
    defer ctx.library.next_id = saved_next_id;
    const revision = ctx.library.revision;
    const assets_revision = ctx.assets.revision;
    try std.testing.expectEqual(id, try ctx.library.registerFrozenFile(&ctx, &frozen));
    try std.testing.expectEqual(id, try ctx.library.registerFile(&ctx, tc.source));
    try std.testing.expectEqual(revision, ctx.library.revision);
    try std.testing.expectEqual(assets_revision, ctx.assets.revision);
    var forged = frozen;
    forged.digest[0] ^= 1;
    try std.testing.expectError(error.SourceContentMismatch, ctx.library.registerFrozenFile(&ctx, &forged));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tc.source, .data = "same file now contains different bytes" });
    try std.testing.expectError(error.ResourceContentChanged, ctx.library.registerFile(&ctx, tc.source));
    try std.testing.expectEqual(revision, ctx.library.revision);
    try std.testing.expectEqual(frozen.digest, ctx.library.get(id).?.content_hash);
    const other = try std.fs.path.join(allocator, &.{ tc.root, "another.txt" });
    defer allocator.free(other);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = other, .data = "new file" });
    const auth_count = ctx.external_sources.count;
    try std.testing.expectError(error.ResourceLibraryFull, ctx.library.registerFile(&ctx, other));
    try std.testing.expectEqual(auth_count, ctx.external_sources.count);
}

test "generic duplicate registration checks live grant permissions before returning an existing id" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    for (0..3) |variant| {
        var tc = try LibraryCase.init();
        defer tc.deinit();
        var ctx: RuntimeContext = undefined;
        try tc.open(&ctx);
        defer ctx.deinit();
        const id = try ctx.library.registerFile(&ctx, tc.source);
        var frozen = try external_sources.readFileSnapshot(&ctx, tc.source);
        defer frozen.deinit(allocator);
        const grant_id = ctx.external_sources.findFile(&frozen).?;
        const revision = ctx.library.revision;
        const assets_revision = ctx.assets.revision;
        const source_count = ctx.external_sources.count;
        const next_grant_id = ctx.mounts.next_grant_id;
        // The snapshot has already crossed the guarded Source boundary.
        // Reuse must only consult the current mount, even without an IO port.
        ctx.io = null;
        try std.testing.expectEqual(id, try ctx.library.registerFrozenFile(&ctx, &frozen));
        if (variant == 0) {
            try std.testing.expect(ctx.mounts.revokeExternal(allocator, grant_id));
            try std.testing.expectError(error.ExternalGrantNotFound, ctx.library.registerFrozenFile(&ctx, &frozen));
        } else {
            var selected: usize = undefined;
            for (ctx.mounts.grants, 0..) |grant, index| {
                if (grant.id == grant_id) selected = index;
            }
            if (variant == 1) {
                ctx.mounts.grants[selected].access = .read_write;
                try std.testing.expectError(error.ReadOnlySourceRequired, ctx.library.registerFrozenFile(&ctx, &frozen));
            } else {
                const alternate = try std.fs.path.join(allocator, &.{ tc.root, "different-locator.bin" });
                allocator.free(ctx.mounts.grants[selected].path);
                ctx.mounts.grants[selected].path = alternate;
                try std.testing.expectError(error.InvalidExternalGrant, ctx.library.registerFrozenFile(&ctx, &frozen));
            }
        }
        try std.testing.expectEqual(@as(usize, 1), ctx.library.count);
        try std.testing.expectEqual(revision, ctx.library.revision);
        try std.testing.expectEqual(assets_revision, ctx.assets.revision);
        try std.testing.expectEqual(source_count, ctx.external_sources.count);
        try std.testing.expectEqual(next_grant_id, ctx.mounts.next_grant_id);
    }
}

test "generic catalog publication failure preserves resources and retries the retained source dependency" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tc = try LibraryCase.init();
    defer tc.deinit();
    var ctx: RuntimeContext = undefined;
    try tc.open(&ctx);
    defer ctx.deinit();
    _ = try ctx.library.registerFile(&ctx, tc.source);
    const other = try std.fs.path.join(std.testing.allocator, &.{ tc.root, "notes.txt" });
    defer std.testing.allocator.free(other);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = other, .data = "not a PNG" });
    const next_id = ctx.library.next_id;
    const revision = ctx.library.revision;
    const assets_revision = ctx.assets.revision;
    const before = try tc.catalogBytes();
    defer std.testing.allocator.free(before);
    const blocker = try tc.blockCatalog();
    defer std.testing.allocator.free(blocker);
    if (ctx.library.registerFile(&ctx, other)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expectEqual(@as(usize, 1), ctx.library.count);
    try std.testing.expectEqual(next_id, ctx.library.next_id);
    try std.testing.expectEqual(revision, ctx.library.revision);
    try std.testing.expectEqual(assets_revision, ctx.assets.revision);
    const source_count = ctx.external_sources.count;
    try tc.unblockCatalog(blocker);
    const restored = try tc.catalogBytes();
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualSlices(u8, before, restored);
    try std.testing.expectEqual(next_id, try ctx.library.registerFile(&ctx, other));
    try std.testing.expectEqual(source_count, ctx.external_sources.count);
}
