const std = @import("std");
const runtime_pack = @import("runtime_pack.zig");

pub const manifest_path = runtime_pack.payload_manifest_path;

pub const Kind = enum { builtin, legacy_shell };

pub const Candidate = struct {
    manifest: std.json.Parsed(runtime_pack.Manifest),
    manifest_path: []const u8,
    kind: Kind,

    pub fn deinit(self: *Candidate) void {
        self.manifest.deinit();
        self.* = undefined;
    }

    pub fn verify(self: *const Candidate, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
        switch (self.kind) {
            .builtin => try runtime_pack.verifyPayload(self.manifest.value, allocator, io, dir),
            .legacy_shell => try runtime_pack.verifyShell(self.manifest.value, allocator, io, dir),
        }
    }
};

pub fn legacyCandidate(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Candidate {
    return .{
        .manifest = try runtime_pack.verifyShellFile(allocator, io, dir),
        .manifest_path = runtime_pack.shell_manifest_path,
        .kind = .legacy_shell,
    };
}

pub fn verifyCandidate(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, allow_legacy: bool) !Candidate {
    dir.access(io, manifest_path, .{}) catch |err| {
        if (err != error.FileNotFound) return err;
        if (!allow_legacy) return error.PayloadNotFound;
        return legacyCandidate(allocator, io, dir);
    };
    return .{
        .manifest = try runtime_pack.verifyPayloadFile(allocator, io, dir),
        .manifest_path = manifest_path,
        .kind = .builtin,
    };
}

test "legacy Shell is never an implicit payload fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.PayloadNotFound, verifyCandidate(std.testing.allocator, std.testing.io, tmp.dir, false));
}
