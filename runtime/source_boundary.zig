//! New ordinary-file references cannot turn managed application/data files into
//! external Sources. Compare both declared roots and final, opened-object paths.
//! This is an application boundary, not a sandbox against the operating user.
const std = @import("std");
const environment = @import("vne").environment;

extern "kernel32" fn GetModuleHandleExW(flags: u32, address: *const anyopaque, module: *?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, filename: [*]u16, capacity: u32) callconv(.winapi) u32;

fn normalized(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidExternalPath;
    const result = try std.fs.path.resolve(allocator, &.{path});
    if (@import("builtin").os.tag == .windows) for (result) |*byte| {
        if (byte.* == '/') byte.* = '\\';
        byte.* = std.ascii.toLower(byte.*);
    };
    return result;
}

fn contains(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (parent.len == 0 or child.len <= parent.len or !std.mem.startsWith(u8, child, parent)) return false;
    return parent[parent.len - 1] == '/' or parent[parent.len - 1] == '\\' or child[parent.len] == '/' or child[parent.len] == '\\';
}

fn rejectRoot(allocator: std.mem.Allocator, io: std.Io, input: []const u8, final: []const u8, root: []const u8) !void {
    if (root.len == 0) return error.InvalidSourceContext;
    const lexical = try normalized(allocator, root);
    defer allocator.free(lexical);
    if (contains(lexical, input) or contains(lexical, final)) return error.ManagedSourceForbidden;
    const physical = try environment.canonicalPath(allocator, io, root);
    defer allocator.free(physical);
    const physical_normalized = try normalized(allocator, physical);
    defer allocator.free(physical_normalized);
    if (contains(physical_normalized, input) or contains(physical_normalized, final)) return error.ManagedSourceForbidden;
}

fn moduleAnchor() void {}

/// The Runtime can be embedded in Python. Its own containing module, never the
/// embedding process's EXE, identifies the application code being protected.
fn modulePath(allocator: std.mem.Allocator) ![]u8 {
    if (@import("builtin").os.tag != .windows) return error.UnsupportedPlatform;
    var module: ?*anyopaque = null;
    if (GetModuleHandleExW(6, @ptrCast(&moduleAnchor), &module) == 0 or module == null) return error.SourceModulePathUnavailable;
    var buffer: [32768]u16 = undefined;
    const length = GetModuleFileNameW(module, &buffer, buffer.len);
    if (length == 0) return error.SourceModulePathUnavailable;
    if (length >= buffer.len) return error.NameTooLong;
    return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..length]);
}

fn productRoot(allocator: std.mem.Allocator, io: std.Io, module_dir: []const u8) !?[]u8 {
    // Installed Runtime Packs are siblings of app/, not descendants of its
    // context file. Only a successfully validated installed declaration counts.
    if (std.fs.path.dirname(module_dir)) |parent| {
        const name = std.fs.path.basename(parent);
        if (std.ascii.eqlIgnoreCase(name, "runtime-envs") or std.ascii.eqlIgnoreCase(name, "shells")) {
            if (std.fs.path.dirname(parent)) |root| {
                const app = try std.fs.path.join(allocator, &.{ root, "app" });
                defer allocator.free(app);
                if (environment.load(allocator, io, app)) |loaded| {
                    var context = loaded;
                    defer context.deinit();
                    if (context.form != .installed) return error.InvalidInstalledLayout;
                    return try allocator.dupe(u8, context.product_root);
                } else |err| if (err != error.MissingRunContext) return err;
            }
        }
    }
    var scan = module_dir;
    while (true) {
        if (environment.load(allocator, io, scan)) |loaded| {
            var context = loaded;
            defer context.deinit();
            return try allocator.dupe(u8, context.product_root);
        } else |err| if (err != error.MissingRunContext) return err;
        const parent = std.fs.path.dirname(scan) orelse return null;
        if (std.mem.eql(u8, parent, scan)) return null;
        scan = parent;
    }
}

pub fn check(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8, final_path: []const u8, data_dir: []const u8, resource_dir: []const u8) !void {
    const input = try normalized(allocator, input_path);
    defer allocator.free(input);
    const final = try normalized(allocator, final_path);
    defer allocator.free(final);
    try rejectRoot(allocator, io, input, final, data_dir);
    try rejectRoot(allocator, io, input, final, resource_dir);
    const module = try modulePath(allocator);
    defer allocator.free(module);
    const module_dir = std.fs.path.dirname(module) orelse return error.SourceModulePathUnavailable;
    try rejectRoot(allocator, io, input, final, module_dir);
    if (try productRoot(allocator, io, module_dir)) |root| {
        defer allocator.free(root);
        try rejectRoot(allocator, io, input, final, root);
    }
}

test "source boundaries compare components instead of ambiguous textual prefixes" {
    try std.testing.expect(contains("c:\\managed", "c:\\managed\\a.bin"));
    try std.testing.expect(contains("c:\\managed", "c:\\managed"));
    try std.testing.expect(!contains("c:\\managed", "c:\\managed-sibling\\a.bin"));
    try std.testing.expect(!contains("c:\\managed", "c:\\managed2"));
}

test "the actual containing module is protected without classifying its whole repository" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const module = try modulePath(std.testing.allocator);
    defer std.testing.allocator.free(module);
    try std.testing.expectError(error.ManagedSourceForbidden, check(std.testing.allocator, std.testing.io, module, module, data, resource));
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "outside.bin" });
    defer std.testing.allocator.free(source);
    try check(std.testing.allocator, std.testing.io, source, source, data, resource);
}
