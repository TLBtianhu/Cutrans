//! Internal process roles use one executable; ordinary users never choose them.
const std = @import("std");

pub const Role = enum { host, shell, library };

pub fn parse(arg: []const u8) !?Role {
    if (!std.mem.startsWith(u8, arg, "--role=")) return null;
    return std.meta.stringToEnum(Role, arg["--role=".len..]) orelse error.InvalidProcessRole;
}

pub fn isUnifiedPath(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    return if (@import("builtin").os.tag == .windows) std.ascii.eqlIgnoreCase(name, "cutrans.exe") else std.mem.eql(u8, name, "cutrans");
}

/// Only the new unified controller changes child selection. Existing entries
/// retain their current executable/Pack path as the rollback path.
pub fn currentIfUnified(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const current = try std.process.executablePathAlloc(io, allocator);
    errdefer allocator.free(current);
    if (!isUnifiedPath(current)) {
        allocator.free(current);
        return null;
    }
    return current;
}

test "internal role names are closed and do not affect ordinary arguments" {
    try std.testing.expect((try parse("--mode=portable")) == null);
    try std.testing.expectEqual(Role.host, (try parse("--role=host")).?);
    try std.testing.expectEqual(Role.shell, (try parse("--role=shell")).?);
    try std.testing.expectEqual(Role.library, (try parse("--role=library")).?);
    try std.testing.expectError(error.InvalidProcessRole, parse("--role=controller"));
    try std.testing.expectError(error.InvalidProcessRole, parse("--role="));
    try std.testing.expect(isUnifiedPath("C:/apps/Cutrans.exe"));
    try std.testing.expect(!isUnifiedPath("C:/apps/cutrans_vm.exe"));
}
