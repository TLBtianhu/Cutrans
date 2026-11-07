const std = @import("std");

pub const path = "session/runtime.lock";

pub const Identity = struct {
    id: []const u8,
    version: []const u8,
    abi: []const u8,
    manifest_sha256: [64]u8,
};

pub const Selection = struct {
    runtime: Identity,
    shell: ?Identity = null,
};

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    selection: Selection,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};

fn validToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-' and ch != '+') return false;
    }
    return true;
}

fn validHash(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |ch| {
        if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
    }
    return true;
}

fn validateIdentity(identity: Identity) !void {
    if (!validToken(identity.id) or !validToken(identity.version) or !validToken(identity.abi)) return error.InvalidLockIdentity;
    if (!validHash(&identity.manifest_sha256)) return error.InvalidLockIdentity;
}

fn validate(selection: Selection) !void {
    try validateIdentity(selection.runtime);
    if (selection.shell) |shell| try validateIdentity(shell);
}

pub fn identityEqual(a: Identity, b: Identity) bool {
    return std.mem.eql(u8, a.id, b.id) and
        std.mem.eql(u8, a.version, b.version) and
        std.mem.eql(u8, a.abi, b.abi) and
        std.mem.eql(u8, &a.manifest_sha256, &b.manifest_sha256);
}

const Field = enum {
    runtime_id,
    runtime_version,
    runtime_abi,
    runtime_manifest_sha256,
    shell_id,
    shell_version,
    shell_abi,
    shell_manifest_sha256,
};

fn putText(owned: *Owned, field: Field, value: []const u8) !void {
    if (field == .runtime_manifest_sha256 or field == .shell_manifest_sha256) {
        if (!validHash(value)) return error.InvalidRuntimeLock;
        if (field == .runtime_manifest_sha256) {
            owned.selection.runtime.manifest_sha256 = value[0..64].*;
        } else {
            if (owned.selection.shell == null) owned.selection.shell = std.mem.zeroes(@TypeOf(owned.selection.shell.?));
            owned.selection.shell.?.manifest_sha256 = value[0..64].*;
        }
        return;
    }
    const copied = try owned.arena.allocator().dupe(u8, value);
    if (field == .shell_id or field == .shell_version or field == .shell_abi) {
        if (owned.selection.shell == null) owned.selection.shell = std.mem.zeroes(@TypeOf(owned.selection.shell.?));
    }
    switch (field) {
        .runtime_id => owned.selection.runtime.id = copied,
        .runtime_version => owned.selection.runtime.version = copied,
        .runtime_abi => owned.selection.runtime.abi = copied,
        .shell_id => owned.selection.shell.?.id = copied,
        .shell_version => owned.selection.shell.?.version = copied,
        .shell_abi => owned.selection.shell.?.abi = copied,
        else => unreachable,
    }
}

fn parse(allocator: std.mem.Allocator, text: []const u8) !Owned {
    var owned = Owned{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .selection = .{ .runtime = std.mem.zeroes(Identity) },
    };
    errdefer owned.deinit();
    var format_seen = false;
    var seen: [8]bool = @splat(false);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "cutrans_runtime_lock=1")) {
            if (format_seen) return error.InvalidRuntimeLock;
            format_seen = true;
            continue;
        }
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidRuntimeLock;
        const key = line[0..separator];
        const value = line[separator + 1 ..];
        const field = std.meta.stringToEnum(Field, key) orelse return error.InvalidRuntimeLock;
        const index = @backingInt(field);
        if (seen[index]) return error.InvalidRuntimeLock;
        seen[index] = true;
        try putText(&owned, field, value);
    }
    if (!format_seen) return error.InvalidRuntimeLock;
    for (seen[0..4]) |present| {
        if (!present) return error.InvalidRuntimeLock;
    }
    if ((seen[4] or seen[5] or seen[6] or seen[7]) and !(seen[4] and seen[5] and seen[6] and seen[7])) return error.InvalidRuntimeLock;
    try validate(owned.selection);
    return owned;
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !?Owned {
    var dir = std.Io.Dir.openDirAbsolute(io, data_dir, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer dir.close(io);
    const text = dir.readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(text);
    return try parse(allocator, text);
}

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendIdentity(out: *std.ArrayList(u8), allocator: std.mem.Allocator, prefix: []const u8, identity: Identity) !void {
    try appendFmt(out, allocator, "{s}_id={s}\n{s}_version={s}\n{s}_abi={s}\n{s}_manifest_sha256={s}\n", .{ prefix, identity.id, prefix, identity.version, prefix, identity.abi, prefix, &identity.manifest_sha256 });
}

pub fn save(selection: Selection, allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !void {
    try validate(selection);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "cutrans_runtime_lock=1\n");
    try appendIdentity(&out, allocator, "runtime", selection.runtime);
    if (selection.shell) |shell| try appendIdentity(&out, allocator, "shell", shell);
    try std.Io.Dir.cwd().createDirPath(io, data_dir);
    var dir = try std.Io.Dir.openDirAbsolute(io, data_dir, .{});
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, out.items);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

test "runtime selection lock round trip preserves runtime and shell identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const selection = Selection{
        .runtime = .{ .id = "cutrans-vm", .version = "0.1.0", .abi = "windows-x64", .manifest_sha256 = @splat('a') },
        .shell = .{ .id = "desktop-shell", .version = "0.2.0", .abi = "windows-x64", .manifest_sha256 = @splat('b') },
    };
    try save(selection, std.testing.allocator, std.testing.io, root);
    var restored = (try load(std.testing.allocator, std.testing.io, root)).?;
    defer restored.deinit();
    try std.testing.expect(identityEqual(selection.runtime, restored.selection.runtime));
    try std.testing.expect(identityEqual(selection.shell.?, restored.selection.shell.?));
    try std.testing.expect(!identityEqual(selection.runtime, selection.shell.?));
}

test "invalid or partial lock is rejected without replacing valid state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const selection = Selection{ .runtime = .{ .id = "cutrans-vm", .version = "0.1.0", .abi = "windows-x64", .manifest_sha256 = @splat('a') } };
    try save(selection, std.testing.allocator, std.testing.io, root);
    try tmp.dir.createDirPath(std.testing.io, "session");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "session/bad.lock", .data = "cutrans_runtime_lock=1\nruntime_id=C:/host\n" });
    var atomic = try tmp.dir.createFileAtomic(std.testing.io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(std.testing.io);
    try atomic.file.writeStreamingAll(std.testing.io, "cutrans_runtime_lock=1\nunknown=value\n");
    try atomic.file.sync(std.testing.io);
    try atomic.replace(std.testing.io);
    try std.testing.expectError(error.InvalidRuntimeLock, load(std.testing.allocator, std.testing.io, root));
    try std.testing.expectError(error.InvalidLockIdentity, save(.{ .runtime = .{ .id = "C:/host", .version = "1", .abi = "windows-x64", .manifest_sha256 = @splat('a') } }, std.testing.allocator, std.testing.io, root));
}
