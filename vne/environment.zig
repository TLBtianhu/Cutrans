//! Resolve a declared product instance before loading Runtime or a Shell.
//! No cwd, home, PATH, or inherited application-data variable is a data root.
const std = @import("std");
const builtin = @import("builtin");
const launch = @import("launch.zig");
const product = @import("product.zig");

pub const context_filename = "cutrans-context.json";
pub const Channel = product.Channel;
const Services = struct { updates: bool, accounts: bool, telemetry: bool };
const Record = struct {
    format: []const u8,
    product_id: []const u8,
    version: []const u8,
    channel: Channel,
    form: launch.Mode,
    development_data_root: []const u8 = "",
    services: Services,
};
const Instance = struct {
    format: []const u8,
    product_id: []const u8,
    form: launch.Mode,
    channel: Channel,
    purpose: launch.Purpose,
};

fn separator(c: u8) bool {
    return c == '/' or c == '\\';
}

fn normalized(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.PathMustBeAbsolute;
    const result = try std.fs.path.resolve(allocator, &.{path});
    if (builtin.os.tag == .windows) for (result) |*c| {
        if (c.* == '/') c.* = '\\';
        c.* = std.ascii.toLower(c.*);
    };
    return result;
}

/// Resolve existing ancestors, including junctions, without creating anything.
pub fn canonicalPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const lexical = try normalized(allocator, path);
    defer allocator.free(lexical);
    var ancestor: []const u8 = lexical;
    while (true) {
        if (std.Io.Dir.cwd().realPathFileAlloc(io, ancestor, allocator)) |physical| {
            defer allocator.free(physical);
            const suffix = std.mem.trimStart(u8, lexical[ancestor.len..], "/\\");
            const joined = if (suffix.len == 0) try allocator.dupe(u8, physical) else try std.fs.path.join(allocator, &.{ physical, suffix });
            defer allocator.free(joined);
            return normalized(allocator, joined);
        } else |err| switch (err) {
            error.FileNotFound => ancestor = std.fs.path.dirname(ancestor) orelse return error.PathAncestorNotFound,
            else => return err,
        }
    }
}

fn contains(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (!std.mem.startsWith(u8, child, parent) or child.len == parent.len) return false;
    return separator(parent[parent.len - 1]) or separator(child[parent.len]);
}

fn recognisedLegacy(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !bool {
    const signatures = [_]struct { []const u8, []const u8 }{
        .{ "session/vm-host.txt", "cutrans_vm_host=1\n" },
        .{ "session/runtime.lock", "cutrans_runtime_lock=1\n" },
        .{ "documents/history.txt", "cutrans_history=1\n" },
        .{ "tasks/journal.txt", "cutrans_tasks=1\n" },
    };
    for (signatures) |signature| {
        const path = try std.fs.path.join(allocator, &.{ data_dir, signature[0] });
        defer allocator.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        defer allocator.free(bytes);
        if (std.mem.startsWith(u8, bytes, signature[1])) return true;
    }
    return false;
}

pub fn ensureSeparateLexically(allocator: std.mem.Allocator, first: []const u8, second: []const u8) !void {
    const a = try normalized(allocator, first);
    defer allocator.free(a);
    const b = try normalized(allocator, second);
    defer allocator.free(b);
    if (contains(a, b) or contains(b, a)) return error.OverlappingResourceAndDataDirectory;
}

pub fn ensureSeparate(allocator: std.mem.Allocator, io: std.Io, first: []const u8, second: []const u8) !void {
    const a = try canonicalPath(allocator, io, first);
    defer allocator.free(a);
    const b = try canonicalPath(allocator, io, second);
    defer allocator.free(b);
    if (contains(a, b) or contains(b, a)) return error.OverlappingResourceAndDataDirectory;
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    form: launch.Mode,
    channel: Channel,
    executable_dir: []u8,
    product_root: []u8,
    development_data_root: ?[]u8,

    pub fn deinit(self: *Context) void {
        self.allocator.free(self.executable_dir);
        self.allocator.free(self.product_root);
        if (self.development_data_root) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn validateMode(self: *const Context, explicit: ?launch.Mode) !launch.Mode {
        if (explicit) |mode| if (mode != self.form) return error.RunContextModeMismatch;
        return self.form;
    }

    /// A packaged staging tree is still a disposable build output. Read-only
    /// inspection may describe its default root; starting an instance may not
    /// silently create daily user data there.
    pub fn requireWritableData(self: *const Context, io: std.Io, override: ?[]const u8, purpose: launch.Purpose) !void {
        const data = try self.dataDir(io, override, purpose);
        defer self.allocator.free(data);
        if (self.form == .development) {
            try ensureSeparate(self.allocator, io, self.product_root, data);
        } else {
            // Only the dedicated data subtree can hold state within a product
            // root. All application assets and every optional Pack stay read-only.
            if (contains(data, self.product_root)) return error.OverlappingResourceAndDataDirectory;
            if (contains(self.product_root, data)) {
                const allowed = try std.fs.path.join(self.allocator, &.{ self.product_root, "data" });
                defer self.allocator.free(allowed);
                if (!contains(allowed, data)) return error.OverlappingResourceAndDataDirectory;
            }
        }
        // An explicit --data cannot turn disposable build output into storage.
        for ([_][]const u8{ self.product_root, data }) |start| {
            var scan = start;
            while (true) {
                if (try readRecord(self.allocator, io, scan)) |parsed| {
                    defer parsed.deinit();
                    if (std.mem.eql(u8, parsed.value.format, "cutrans-run-context/1") and
                        std.mem.eql(u8, parsed.value.product_id, product.id) and parsed.value.form == .development)
                    {
                        ensureSeparate(self.allocator, io, scan, data) catch |err| {
                            if (override == null and self.form != .development and purpose == .normal) return error.StagingRequiresExplicitDataDirectory;
                            return err;
                        };
                    }
                }
                const parent = std.fs.path.dirname(scan) orelse break;
                if (std.mem.eql(u8, parent, scan)) break;
                scan = parent;
            }
        }
    }

    pub fn checkInstance(self: *const Context, io: std.Io, data_dir: []const u8, purpose: launch.Purpose, create: bool) !void {
        const marker = try std.fs.path.join(self.allocator, &.{ data_dir, "cutrans-instance.json" });
        defer self.allocator.free(marker);
        const text = std.Io.Dir.cwd().readFileAlloc(io, marker, self.allocator, .limited(16 * 1024)) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            var empty = true;
            if (std.Io.Dir.openDirAbsolute(io, data_dir, .{ .iterate = true })) |opened| {
                const dir = opened;
                defer dir.close(io);
                var iterator = dir.iterate();
                empty = (try iterator.next(io)) == null;
            } else |open_err| if (open_err != error.FileNotFound) return open_err;
            if (!empty and purpose != .normal) return error.UnmarkedVerificationDataDirectory;
            if (!empty and !try recognisedLegacy(self.allocator, io, data_dir)) return error.UnrecognisedDataDirectory;
            if (!empty) {
                const expected = try self.dataDir(io, null, .normal);
                defer self.allocator.free(expected);
                const actual = try canonicalPath(self.allocator, io, data_dir);
                defer self.allocator.free(actual);
                if (!std.mem.eql(u8, expected, actual)) return error.UnmarkedLegacyDataOutsideDefault;
            }
            // Legacy normal sessions stay readable without rewriting their identity.
            if (!create or !empty) return;
            const content = try std.fmt.allocPrint(self.allocator, "{{\"format\":\"cutrans-instance/1\",\"product_id\":\"{s}\",\"form\":\"{s}\",\"channel\":\"{s}\",\"purpose\":\"{s}\"}}\n", .{ product.id, @tagName(self.form), @tagName(self.channel), @tagName(purpose) });
            defer self.allocator.free(content);
            var atomic = try std.Io.Dir.cwd().createFileAtomic(io, marker, .{ .make_path = true });
            defer atomic.deinit(io);
            try atomic.file.writeStreamingAll(io, content);
            try atomic.file.sync(io);
            atomic.link(io) catch |link_err| {
                if (link_err == error.PathAlreadyExists) return self.checkInstance(io, data_dir, purpose, false);
                return link_err;
            };
            break :blk try self.allocator.dupe(u8, content);
        };
        defer self.allocator.free(text);
        const parsed = std.json.parseFromSlice(Instance, self.allocator, text, .{ .allocate = .alloc_always }) catch return error.InvalidInstanceIdentity;
        defer parsed.deinit();
        const identity = parsed.value;
        if (!std.mem.eql(u8, identity.format, "cutrans-instance/1") or !std.mem.eql(u8, identity.product_id, product.id) or
            identity.form != self.form or identity.channel != self.channel or identity.purpose != purpose) return error.InstanceIdentityMismatch;
    }

    pub fn dataDir(self: *const Context, io: std.Io, override: ?[]const u8, purpose: launch.Purpose) ![]u8 {
        if (purpose != .normal and override == null) return error.VerificationRequiresExplicitDataDirectory;
        const declared = override orelse self.development_data_root orelse blk: {
            const data = try std.fs.path.join(self.allocator, &.{ self.product_root, "data" });
            defer self.allocator.free(data);
            break :blk try canonicalPath(self.allocator, io, data);
        };
        // `declared` may be a temporary allocated default. Always return an owned canonical path.
        const is_allocated_default = override == null and self.development_data_root == null;
        defer if (is_allocated_default) self.allocator.free(declared);
        const result = try canonicalPath(self.allocator, io, declared);
        errdefer self.allocator.free(result);
        if (self.form == .development and purpose == .normal) try ensureSeparate(self.allocator, io, self.product_root, result);
        return result;
    }
};

fn readRecord(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !?std.json.Parsed(Record) {
    const file = try std.fs.path.join(allocator, &.{ directory, context_filename });
    defer allocator.free(file);
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, allocator, .limited(16 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(text);
    return std.json.parseFromSlice(Record, allocator, text, .{ .allocate = .alloc_always }) catch return error.InvalidRunContext;
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, exe_dir: []const u8) !Context {
    const canonical_exe = try canonicalPath(allocator, io, exe_dir);
    errdefer allocator.free(canonical_exe);
    var location = try allocator.dupe(u8, canonical_exe);
    defer allocator.free(location);
    var parsed = try readRecord(allocator, io, location);
    if (parsed == null) {
        const parent = std.fs.path.dirname(canonical_exe) orelse return error.MissingRunContext;
        if (std.mem.eql(u8, std.fs.path.basename(parent), "shells")) {
            const next = try std.fs.path.resolve(allocator, &.{ canonical_exe, "..", "..", "app" });
            allocator.free(location);
            location = next;
            parsed = try readRecord(allocator, io, location);
        } else if (std.mem.eql(u8, std.fs.path.basename(canonical_exe), "nanoui-library") or std.mem.eql(u8, std.fs.path.basename(canonical_exe), "shell")) {
            const next = try allocator.dupe(u8, parent);
            allocator.free(location);
            location = next;
            parsed = try readRecord(allocator, io, location);
        }
    }
    const record = parsed orelse return error.MissingRunContext;
    defer record.deinit();
    const value = record.value;
    if (!std.mem.eql(u8, value.format, "cutrans-run-context/1") or
        !std.mem.eql(u8, value.product_id, product.id) or
        !std.mem.eql(u8, value.version, product.version)) return error.RunContextIdentityMismatch;
    if (value.services.updates or value.services.accounts or value.services.telemetry) return error.UnconfiguredServiceEnabled;
    const root = switch (value.form) {
        .development => if (std.mem.eql(u8, std.fs.path.basename(location), "bin")) try std.fs.path.resolve(allocator, &.{ location, ".." }) else try allocator.dupe(u8, location),
        .portable => try allocator.dupe(u8, location),
        .installed => blk: {
            if (!std.mem.eql(u8, std.fs.path.basename(location), "app")) return error.InvalidInstalledLayout;
            break :blk try std.fs.path.resolve(allocator, &.{ location, ".." });
        },
    };
    defer allocator.free(root);
    const canonical_root = try canonicalPath(allocator, io, root);
    errdefer allocator.free(canonical_root);
    var dev_data: ?[]u8 = null;
    if (value.form == .development) {
        if (value.development_data_root.len == 0) return error.MissingDevelopmentDataRoot;
        dev_data = try canonicalPath(allocator, io, value.development_data_root);
        errdefer allocator.free(dev_data.?);
        const build_root = if (std.mem.eql(u8, std.fs.path.basename(canonical_exe), "bin")) std.fs.path.dirname(canonical_exe).? else canonical_exe;
        try ensureSeparate(allocator, io, build_root, dev_data.?);
    } else if (value.development_data_root.len != 0) return error.UnexpectedDevelopmentDataRoot;
    return .{ .allocator = allocator, .form = value.form, .channel = value.channel, .executable_dir = canonical_exe, .product_root = canonical_root, .development_data_root = dev_data };
}

test "canonical data aliases agree and ancestor overlap is rejected before IO" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const first = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(first);
    const alias = try std.fs.path.join(std.testing.allocator, &.{ root, "a", "..", "data" });
    defer std.testing.allocator.free(alias);
    const a = try canonicalPath(std.testing.allocator, std.testing.io, first);
    defer std.testing.allocator.free(a);
    const b = try canonicalPath(std.testing.allocator, std.testing.io, alias);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expectError(error.OverlappingResourceAndDataDirectory, ensureSeparate(std.testing.allocator, std.testing.io, root, first));
}

test "instance marker separates purpose and channel, and status creates nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    var context = Context{ .allocator = std.testing.allocator, .form = .portable, .channel = .stable, .executable_dir = try std.testing.allocator.dupe(u8, root), .product_root = try std.testing.allocator.dupe(u8, root), .development_data_root = null };
    defer context.deinit();
    try context.checkInstance(std.testing.io, data, .normal, false);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "data", .{}));
    try context.checkInstance(std.testing.io, data, .verification, true);
    try context.checkInstance(std.testing.io, data, .verification, false);
    try std.testing.expectError(error.InstanceIdentityMismatch, context.checkInstance(std.testing.io, data, .normal, true));
    context.channel = .preview;
    try std.testing.expectError(error.InstanceIdentityMismatch, context.checkInstance(std.testing.io, data, .verification, false));
}

test "verification cannot adopt unmarked data and legacy normal metadata is left alone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, "data/documents");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data/keep.txt", .data = "keep" });
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    var context = Context{ .allocator = std.testing.allocator, .form = .portable, .channel = .stable, .executable_dir = try std.testing.allocator.dupe(u8, root), .product_root = try std.testing.allocator.dupe(u8, root), .development_data_root = null };
    defer context.deinit();
    try std.testing.expectError(error.UnmarkedVerificationDataDirectory, context.checkInstance(std.testing.io, data, .verification, true));
    try std.testing.expectError(error.UnrecognisedDataDirectory, context.checkInstance(std.testing.io, data, .normal, true));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data/documents/history.txt", .data = "cutrans_history=1\n" });
    try context.checkInstance(std.testing.io, data, .normal, true);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "data/cutrans-instance.json", .{}));
    const kept = try tmp.dir.readFileAlloc(std.testing.io, "data/keep.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("keep", kept);
    try tmp.dir.createDirPath(std.testing.io, "other-session/documents");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other-session/documents/history.txt", .data = "cutrans_history=1\n" });
    const other = try std.fs.path.join(std.testing.allocator, &.{ root, "other-session" });
    defer std.testing.allocator.free(other);
    try std.testing.expectError(error.UnmarkedLegacyDataOutsideDefault, context.checkInstance(std.testing.io, other, .normal, false));
}

test "a packaged staging tree permits inspection but requires an explicit writable root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, "build/portable");
    const declaration = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .format = "cutrans-run-context/1",
        .product_id = product.id,
        .version = product.version,
        .channel = "development",
        .form = "development",
        .development_data_root = root,
        .services = .{ .updates = false, .accounts = false, .telemetry = false },
    }, .{});
    defer std.testing.allocator.free(declaration);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build/cutrans-context.json", .data = declaration });
    var context = Context{ .allocator = std.testing.allocator, .form = .portable, .channel = .stable, .executable_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "build", "portable" }), .product_root = try std.fs.path.join(std.testing.allocator, &.{ root, "build", "portable" }), .development_data_root = null };
    defer context.deinit();
    const inspected = try context.dataDir(std.testing.io, null, .normal);
    defer std.testing.allocator.free(inspected);
    const staging_data = try std.fs.path.join(std.testing.allocator, &.{ context.product_root, "data" });
    defer std.testing.allocator.free(staging_data);
    try std.testing.expectError(error.OverlappingResourceAndDataDirectory, context.requireWritableData(std.testing.io, staging_data, .verification));
    try std.testing.expectError(error.StagingRequiresExplicitDataDirectory, context.requireWritableData(std.testing.io, null, .normal));
    const outside_build = try std.fs.path.join(std.testing.allocator, &.{ root, "user data" });
    defer std.testing.allocator.free(outside_build);
    try context.requireWritableData(std.testing.io, outside_build, .normal);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "build/portable/data", .{}));
}

test "all optional product packs stay separate from every writable instance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var context = Context{ .allocator = std.testing.allocator, .form = .portable, .channel = .stable, .executable_dir = try canonicalPath(std.testing.allocator, std.testing.io, root), .product_root = try canonicalPath(std.testing.allocator, std.testing.io, root), .development_data_root = null };
    defer context.deinit();
    inline for (.{ "assets/probe-data", "runtime/probe-data", "shell/probe-data", "nanoui-library/probe-data", "app/probe-data", "runtime-envs/default/probe-data", "shells/desktop/probe-data" }) |relative| {
        const data = try std.fs.path.join(std.testing.allocator, &.{ root, relative });
        defer std.testing.allocator.free(data);
        try std.testing.expectError(error.OverlappingResourceAndDataDirectory, context.requireWritableData(std.testing.io, data, .verification));
        context.form = .installed;
        try std.testing.expectError(error.OverlappingResourceAndDataDirectory, context.requireWritableData(std.testing.io, data, .diagnostic));
        context.form = .portable;
    }
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data", "verification" });
    defer std.testing.allocator.free(data);
    try context.requireWritableData(std.testing.io, data, .verification);
}
