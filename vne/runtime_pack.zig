const std = @import("std");
const abi = @import("abi.zig");

pub const manifest_path = "runtime-pack.json";

pub const File = struct {
    path: []const u8,
    byteLength: u64,
    sha256: []const u8,
};

pub const Manifest = struct {
    format: []const u8,
    id: []const u8,
    version: []const u8,
    abi: []const u8,
    entry: []const u8,
    vm_schema: u32,
    host_api: u32,
    document_schema: u32,
    required_capabilities: []const []const u8,
    files: []const File,
};

fn validRelative(path: []const u8) bool {
    return path.len > 0 and !std.fs.path.isAbsolute(path) and std.mem.indexOf(u8, path, "..") == null;
}

pub const shell_manifest_path = "shell-pack.json";

fn verifyMetadata(manifest: Manifest, format: []const u8, entry: []const u8) !void {
    if (!std.mem.eql(u8, manifest.format, format)) return error.InvalidRuntimePack;
    if (manifest.id.len == 0 or manifest.version.len == 0) return error.InvalidRuntimePack;
    if (!std.mem.eql(u8, manifest.abi, abi.nativeAbi())) return error.IncompatibleRuntimeAbi;
    if (!std.mem.eql(u8, manifest.entry, entry)) return error.InvalidRuntimeEntry;
    if (manifest.vm_schema != 1 or manifest.host_api != abi.version or manifest.document_schema != 3) return error.IncompatibleRuntimeSchema;
    var has_entry = false;
    for (manifest.files, 0..) |file, i| {
        if (!validRelative(file.path) or file.sha256.len != 64) return error.InvalidRuntimeFile;
        if (std.mem.eql(u8, file.path, manifest.entry)) has_entry = true;
        for (manifest.files[0..i]) |previous| {
            if (std.mem.eql(u8, file.path, previous.path)) return error.DuplicateRuntimeFile;
        }
    }
    if (!has_entry) return error.MissingRuntimeEntry;
    for (manifest.required_capabilities, 0..) |id, i| {
        if (id.len == 0) return error.InvalidRuntimeCapability;
        for (manifest.required_capabilities[0..i]) |previous| {
            if (std.mem.eql(u8, id, previous)) return error.DuplicateRuntimeCapability;
        }
    }
}

pub fn verifyKind(manifest: Manifest, format: []const u8, entry: []const u8, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    try verifyMetadata(manifest, format, entry);
    for (manifest.files) |file| {
        const bytes = try dir.readFileAlloc(io, file.path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(bytes);
        if (bytes.len != file.byteLength) return error.RuntimeFileSizeMismatch;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const actual = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &actual, file.sha256)) return error.RuntimeFileHashMismatch;
    }
}

pub fn verify(manifest: Manifest, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    return verifyKind(manifest, "cutrans-runtime-pack/1", abi.runtimeLibraryName(), allocator, io, dir);
}

pub fn verifyShell(manifest: Manifest, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    return verifyKind(manifest, "cutrans-shell-pack/1", manifest.entry, allocator, io, dir);
}

fn verifyFileKind(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, format: []const u8, entry: []const u8) !std.json.Parsed(Manifest) {
    const text = try dir.readFileAlloc(io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    const parsed = try std.json.parseFromSlice(Manifest, allocator, text, .{ .ignore_unknown_fields = false, .allocate = .alloc_always });
    errdefer parsed.deinit();
    try verifyKind(parsed.value, format, entry, allocator, io, dir);
    return parsed;
}

pub fn verifyFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !std.json.Parsed(Manifest) {
    return verifyFileKind(allocator, io, dir, manifest_path, "cutrans-runtime-pack/1", abi.runtimeLibraryName());
}

pub fn verifyShellFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !std.json.Parsed(Manifest) {
    const text = try dir.readFileAlloc(io, shell_manifest_path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    const parsed = try std.json.parseFromSlice(Manifest, allocator, text, .{ .ignore_unknown_fields = false, .allocate = .alloc_always });
    errdefer parsed.deinit();
    try verifyShell(parsed.value, allocator, io, dir);
    return parsed;
}

fn hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "runtime pack verifies its native entry and rejects drift" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = abi.runtimeLibraryName(), .data = "runtime" });
    const digest = hex("runtime");
    const files = [_]File{.{ .path = abi.runtimeLibraryName(), .byteLength = 7, .sha256 = &digest }};
    const capabilities = [_][]const u8{"node.testsrc"};
    const manifest = Manifest{
        .format = "cutrans-runtime-pack/1",
        .id = "cutrans-vm",
        .version = "0.1.0",
        .abi = abi.nativeAbi(),
        .entry = abi.runtimeLibraryName(),
        .vm_schema = 1,
        .host_api = abi.version,
        .document_schema = 3,
        .required_capabilities = &capabilities,
        .files = &files,
    };
    try verify(manifest, std.testing.allocator, std.testing.io, tmp.dir);
    var incompatible = manifest;
    incompatible.abi = "incompatible-os";
    try std.testing.expectError(error.IncompatibleRuntimeAbi, verify(incompatible, std.testing.allocator, std.testing.io, tmp.dir));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = abi.runtimeLibraryName(), .data = "changed" });
    try std.testing.expectError(error.RuntimeFileSizeMismatch, verify(manifest, std.testing.allocator, std.testing.io, tmp.dir));
    var missing_entry = manifest;
    missing_entry.entry = "missing.dll";
    try std.testing.expectError(error.InvalidRuntimeEntry, verify(missing_entry, std.testing.allocator, std.testing.io, tmp.dir));
}

test "verified manifest owns its strings after the source text is released" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = abi.runtimeLibraryName(), .data = "runtime" });
    const digest = hex("runtime");
    const text = try std.fmt.allocPrint(std.testing.allocator, "{{\"format\":\"cutrans-runtime-pack/1\",\"id\":\"cutrans-vm\",\"version\":\"0.1.0\",\"abi\":\"{s}\",\"entry\":\"{s}\",\"vm_schema\":1,\"host_api\":{d},\"document_schema\":3,\"required_capabilities\":[\"node.testsrc\"],\"files\":[{{\"path\":\"{s}\",\"byteLength\":7,\"sha256\":\"{s}\"}}]}}\n", .{ abi.nativeAbi(), abi.runtimeLibraryName(), abi.version, abi.runtimeLibraryName(), &digest });
    defer std.testing.allocator.free(text);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = text });
    const parsed = try verifyFile(std.testing.allocator, std.testing.io, tmp.dir);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(abi.runtimeLibraryName(), parsed.value.entry);
    try std.testing.expectEqualStrings(abi.nativeAbi(), parsed.value.abi);
    try std.testing.expectEqualStrings(&digest, parsed.value.files[0].sha256);
}

test "shell packs admit distinct entry points without weakening file verification" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "library.exe", .data = "frontend" });
    const digest = hex("frontend");
    const files = [_]File{.{ .path = "library.exe", .byteLength = 8, .sha256 = &digest }};
    const capabilities = [_][]const u8{"node.testsrc"};
    const manifest = Manifest{
        .format = "cutrans-shell-pack/1",
        .id = "nanoui-library",
        .version = "0.1.0",
        .abi = abi.nativeAbi(),
        .entry = "library.exe",
        .vm_schema = 1,
        .host_api = abi.version,
        .document_schema = 3,
        .required_capabilities = &capabilities,
        .files = &files,
    };
    try verifyShell(manifest, std.testing.allocator, std.testing.io, tmp.dir);
    var missing = manifest;
    missing.entry = "missing.exe";
    try std.testing.expectError(error.MissingRuntimeEntry, verifyShell(missing, std.testing.allocator, std.testing.io, tmp.dir));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "library.exe", .data = "modified" });
    try std.testing.expectError(error.RuntimeFileSizeMismatch, verifyShell(manifest, std.testing.allocator, std.testing.io, tmp.dir));
}
