const std = @import("std");
const launch = @import("launch.zig");

pub const version: u32 = 1;
pub const max_message = 1024;
pub const lifecycle_path = "session/vm-host.txt";

pub const Action = enum { status, stop, rpc };
pub const State = enum { starting, running, stopping, stopped, degraded };

pub const Snapshot = struct {
    state: State = .stopped,
    mode: launch.Mode = .development,
    boot_id: u64 = 0,
    last_shutdown_abnormal: bool = false,
    abi_version: u32 = 0,
    document_fingerprint: u64 = 0,
    present_count: u64 = 0,
};

pub fn endpoint(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(data_dir)) return error.InvalidDataDirectory;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data_dir, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "\\\\.\\pipe\\cutrans-vm-{s}", .{&hex});
}

pub fn writeAction(buffer: []u8, action: Action) ![]const u8 {
    return std.fmt.bufPrint(buffer, "cutrans_vm_host={d}\ncommand={s}\n", .{ version, @tagName(action) });
}

pub fn parseAction(text: []const u8) !Action {
    if (std.mem.eql(u8, text, "cutrans_vm_host=1\ncommand=status\n")) return .status;
    if (std.mem.eql(u8, text, "cutrans_vm_host=1\ncommand=stop\n")) return .stop;
    return error.InvalidHostRequest;
}

pub fn writeSnapshot(buffer: []u8, snapshot: Snapshot) ![]const u8 {
    return std.fmt.bufPrint(buffer, "cutrans_vm_host={d}\nstate={s}\nmode={s}\nboot_id={d}\nlast_shutdown_abnormal={d}\nabi={d}\ndocument={d}\npresent={d}\n", .{
        version,
        @tagName(snapshot.state),
        @tagName(snapshot.mode),
        snapshot.boot_id,
        @intFromBool(snapshot.last_shutdown_abnormal),
        snapshot.abi_version,
        snapshot.document_fingerprint,
        snapshot.present_count,
    });
}

const Field = enum { state, mode, boot_id, last_shutdown_abnormal, abi, document, present };

pub fn parseSnapshot(text: []const u8) !Snapshot {
    var result: Snapshot = .{};
    var header_seen = false;
    var seen: [7]bool = @splat(false);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "cutrans_vm_host=1")) {
            if (header_seen) return error.InvalidHostSnapshot;
            header_seen = true;
            continue;
        }
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidHostSnapshot;
        const key = line[0..separator];
        const value = line[separator + 1 ..];
        const field = std.meta.stringToEnum(Field, key) orelse return error.InvalidHostSnapshot;
        const index = @intFromEnum(field);
        if (seen[index]) return error.InvalidHostSnapshot;
        seen[index] = true;
        switch (field) {
            .state => result.state = std.meta.stringToEnum(State, value) orelse return error.InvalidHostSnapshot,
            .mode => result.mode = launch.parseMode(value) catch return error.InvalidHostSnapshot,
            .boot_id => result.boot_id = std.fmt.parseInt(u64, value, 10) catch return error.InvalidHostSnapshot,
            .last_shutdown_abnormal => {
                const flag = std.fmt.parseInt(u1, value, 10) catch return error.InvalidHostSnapshot;
                result.last_shutdown_abnormal = flag != 0;
            },
            .abi => result.abi_version = std.fmt.parseInt(u32, value, 10) catch return error.InvalidHostSnapshot,
            .document => result.document_fingerprint = std.fmt.parseInt(u64, value, 10) catch return error.InvalidHostSnapshot,
            .present => result.present_count = std.fmt.parseInt(u64, value, 10) catch return error.InvalidHostSnapshot,
        }
    }
    if (!header_seen or result.boot_id == 0 or result.abi_version == 0) return error.InvalidHostSnapshot;
    for (seen) |present| if (!present) return error.InvalidHostSnapshot;
    return result;
}

test "host endpoint isolates data roots without exposing their paths" {
    const first = try endpoint(std.testing.allocator, "C:/one");
    defer std.testing.allocator.free(first);
    const second = try endpoint(std.testing.allocator, "C:/two");
    defer std.testing.allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.startsWith(u8, first, "\\\\.\\pipe\\cutrans-vm-"));
    try std.testing.expect(std.mem.indexOf(u8, first, "C:/one") == null);
    try std.testing.expectError(error.InvalidDataDirectory, endpoint(std.testing.allocator, "relative"));
}

test "host protocol round trips commands and real lifecycle state" {
    var buffer: [max_message]u8 = undefined;
    const request = try writeAction(&buffer, .stop);
    try std.testing.expectEqual(Action.stop, try parseAction(request));
    try std.testing.expectError(error.InvalidHostRequest, parseAction("cutrans_vm_host=1\ncommand=kill\n"));
    const expected = Snapshot{
        .state = .running,
        .mode = .installed,
        .boot_id = 7,
        .last_shutdown_abnormal = true,
        .abi_version = 7,
        .document_fingerprint = 42,
        .present_count = 9,
    };
    const encoded = try writeSnapshot(&buffer, expected);
    const actual = try parseSnapshot(encoded);
    try std.testing.expectEqual(expected.state, actual.state);
    try std.testing.expectEqual(expected.mode, actual.mode);
    try std.testing.expectEqual(expected.boot_id, actual.boot_id);
    try std.testing.expectEqual(expected.last_shutdown_abnormal, actual.last_shutdown_abnormal);
    try std.testing.expectEqual(expected.abi_version, actual.abi_version);
    try std.testing.expectEqual(expected.document_fingerprint, actual.document_fingerprint);
    try std.testing.expectEqual(expected.present_count, actual.present_count);
    const duplicate = "cutrans_vm_host=1\nstate=running\nstate=stopped\nmode=installed\nboot_id=7\nlast_shutdown_abnormal=1\nabi=7\ndocument=42\npresent=9\n";
    try std.testing.expectError(error.InvalidHostSnapshot, parseSnapshot(duplicate));
}
