//! vm_pack.zig — VM Pack 兼容性、能力与原生依赖审计
//!
//! manifest 只声明事实,不决定加载。verify 还会读取实际文件并校验大小和
//! SHA-256,因此“清单写着存在”不能冒充“依赖已就绪”。

const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const vm_schema = 1;
pub const host_api = @import("vne").abi.version;
pub const document_schema = 3;
pub const manifest_path = "vm-pack.json";

pub const NativeDependency = struct {
    id: []const u8,
    abi: []const u8,
    path: []const u8,
};

pub const PackFile = struct {
    path: []const u8,
    byteLength: u64,
    sha256: []const u8,
};

pub const Manifest = struct {
    format: []const u8,
    id: []const u8,
    version: []const u8,
    vm_schema: u32,
    host_api: u32,
    document_schema: u32,
    required_capabilities: []const []const u8,
    native_dependencies: []const NativeDependency,
    files: []const PackFile,
};

pub const Report = struct {
    capabilities: usize,
    files: usize,
    native_dependencies: usize,
};

pub fn currentNativeAbi() []const u8 {
    const os = @import("builtin").os.tag;
    const arch = @import("builtin").cpu.arch;
    return switch (os) {
        .windows => switch (arch) {
            .x86_64 => "windows-x64",
            .aarch64 => "windows-arm64",
            else => "windows-other",
        },
        .linux => switch (arch) {
            .x86_64 => "linux-x64",
            .aarch64 => "linux-arm64",
            else => "linux-other",
        },
        .macos => switch (arch) {
            .x86_64 => "macos-x64",
            .aarch64 => "macos-arm64",
            else => "macos-other",
        },
        else => "unsupported-os",
    };
}

fn validRelative(path: []const u8) bool {
    return path.len > 0 and !std.fs.path.isAbsolute(path) and std.mem.indexOf(u8, path, "..") == null;
}

fn verifyCapabilities(manifest: Manifest) !void {
    if (manifest.required_capabilities.len != capabilities.declarations.len) return error.CapabilitySetMismatch;
    for (manifest.required_capabilities, 0..) |id, i| {
        if (capabilities.status(id) != .ready) return error.CapabilityNotReady;
        for (manifest.required_capabilities[0..i]) |previous| {
            if (std.mem.eql(u8, previous, id)) return error.DuplicateCapability;
        }
    }
}

fn verifyFiles(manifest: Manifest, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    const required_paths = [_][]const u8{
        "cutrans.exe",
        "cutrans_bootstrap.exe",
        "config/startup.ccb",
        "assets/examples/minimal.cut",
        "assets/examples/pngtest.png",
    };
    for (required_paths) |required| {
        var found = false;
        for (manifest.files) |file| {
            if (std.mem.eql(u8, file.path, required)) found = true;
        }
        if (!found) return error.MissingPackFile;
    }
    for (manifest.native_dependencies) |native| {
        if (!std.mem.eql(u8, native.abi, currentNativeAbi())) return error.IncompatibleNativeDependency;
        if (!validRelative(native.path)) return error.NativeDependencyMismatch;
    }

    for (manifest.files, 0..) |file, i| {
        if (!validRelative(file.path)) return error.InvalidPackPath;
        if (file.sha256.len != 64) return error.InvalidPackHash;
        for (manifest.files[0..i]) |previous| {
            if (std.mem.eql(u8, previous.path, file.path)) return error.DuplicatePackFile;
        }
        const bytes = try dir.readFileAlloc(io, file.path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(bytes);
        if (bytes.len != file.byteLength) return error.PackFileSizeMismatch;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const actual = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &actual, file.sha256)) return error.PackFileHashMismatch;
    }
}

pub fn verify(manifest: Manifest, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Report {
    if (!std.mem.eql(u8, manifest.format, "cutrans-vm-pack/1")) return error.InvalidVmPack;
    if (manifest.id.len == 0 or manifest.version.len == 0) return error.InvalidVmPack;
    if (manifest.vm_schema != vm_schema) return error.UnsupportedVmSchema;
    if (manifest.host_api != host_api) return error.HostApiMismatch;
    if (manifest.document_schema != document_schema) return error.DocumentSchemaMismatch;
    try verifyCapabilities(manifest);
    try verifyFiles(manifest, allocator, io, dir);
    return .{
        .capabilities = manifest.required_capabilities.len,
        .files = manifest.files.len,
        .native_dependencies = manifest.native_dependencies.len,
    };
}

pub fn verifyFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Report {
    const text = try dir.readFileAlloc(io, manifest_path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    const parsed = try std.json.parseFromSlice(Manifest, allocator, text, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    return verify(parsed.value, allocator, io, dir);
}

const required_ids = [_][]const u8{
    "node.testsrc",
    "node.gain",
    "node.invert",
    "node.over",
    "node.resize",
    "image.png.decode",
    "image.png.encode",
};

fn hashText(text: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.mem.eql(u8, path, "config/startup.ccb")) try dir.createDirPath(std.testing.io, "config");
    if (std.mem.eql(u8, path, "assets/examples/minimal.cut") or std.mem.eql(u8, path, "assets/examples/pngtest.png")) {
        try dir.createDirPath(std.testing.io, "assets/examples");
    }
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
}

fn prepareFiles(dir: std.Io.Dir) !void {
    try writeTestFile(dir, "config/startup.ccb", "a");
    try writeTestFile(dir, "assets/examples/minimal.cut", "b");
    try writeTestFile(dir, "assets/examples/pngtest.png", "c");
    try writeTestFile(dir, "cutrans.exe", "e");
    try writeTestFile(dir, "cutrans_bootstrap.exe", "f");
}

fn testManifest(files: []const PackFile, native: []const NativeDependency, required: []const []const u8) Manifest {
    return .{
        .format = "cutrans-vm-pack/1",
        .id = "core",
        .version = "0.1.0",
        .vm_schema = 1,
        .host_api = host_api,
        .document_schema = 3,
        .required_capabilities = required,
        .native_dependencies = native,
        .files = files,
    };
}

test "VM pack JSON and file hashes verify against real files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try prepareFiles(tmp.dir);
    const a = hashText("a");
    const b = hashText("b");
    const c = hashText("c");
    const e = hashText("e");
    const f = hashText("f");
    const files = [_]PackFile{
        .{ .path = "config/startup.ccb", .byteLength = 1, .sha256 = &a },
        .{ .path = "assets/examples/minimal.cut", .byteLength = 1, .sha256 = &b },
        .{ .path = "assets/examples/pngtest.png", .byteLength = 1, .sha256 = &c },
        .{ .path = "cutrans.exe", .byteLength = 1, .sha256 = &e },
        .{ .path = "cutrans_bootstrap.exe", .byteLength = 1, .sha256 = &f },
    };
    const no_native = [_]NativeDependency{};
    const manifest = testManifest(&files, &no_native, &required_ids);
    const json = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{std.json.fmt(manifest, .{})});
    defer std.testing.allocator.free(json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = json });
    const report = try verifyFile(std.testing.allocator, std.testing.io, tmp.dir);
    try std.testing.expectEqual(@as(usize, 7), report.capabilities);
    try std.testing.expectEqual(@as(usize, 5), report.files);
    try std.testing.expectEqual(@as(usize, 0), report.native_dependencies);
}

test "VM pack rejects hash drift incompatible ABI and unknown capabilities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try prepareFiles(tmp.dir);
    const a = hashText("a");
    const b = hashText("b");
    const c = hashText("c");
    const e = hashText("e");
    const f = hashText("f");
    const zeros = "0000000000000000000000000000000000000000000000000000000000000000";
    const files = [_]PackFile{
        .{ .path = "config/startup.ccb", .byteLength = 1, .sha256 = zeros },
        .{ .path = "assets/examples/minimal.cut", .byteLength = 1, .sha256 = &b },
        .{ .path = "assets/examples/pngtest.png", .byteLength = 1, .sha256 = &c },
        .{ .path = "cutrans.exe", .byteLength = 1, .sha256 = &e },
        .{ .path = "cutrans_bootstrap.exe", .byteLength = 1, .sha256 = &f },
    };
    const no_native = [_]NativeDependency{};
    try std.testing.expectError(error.PackFileHashMismatch, verify(testManifest(&files, &no_native, &required_ids), std.testing.allocator, std.testing.io, tmp.dir));

    const incompatible = [_]NativeDependency{.{ .id = "optional-native", .abi = "incompatible-os", .path = "optional.dll" }};
    try std.testing.expectError(error.IncompatibleNativeDependency, verify(testManifest(&files, &incompatible, &required_ids), std.testing.allocator, std.testing.io, tmp.dir));

    var unknown = required_ids;
    unknown[0] = "video.decode";
    try std.testing.expectError(error.CapabilityNotReady, verify(testManifest(&files, &no_native, &unknown), std.testing.allocator, std.testing.io, tmp.dir));
    _ = a;
}
