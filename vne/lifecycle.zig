//! lifecycle.zig — 单进程虚拟环境的持久生命周期记录
//!
//! 记录本数据根上一次环境实例的阶段、启动序号和是否异常结束。它只是落盘的
//! 事实投影，不是控制通道：没有端点、没有请求动作，也不跨进程传递命令。
//! 2026-11-12 起 Host 进程已删除，旧 `session/vm-host.txt` 只读兼容一次，用于
//! 延续 boot_id 与异常结束判断。
const std = @import("std");
const launch = @import("launch.zig");

pub const version: u32 = 1;
pub const max_record = 1024;
pub const record_path = "session/lifecycle.txt";
pub const legacy_record_path = "session/vm-host.txt";
pub const lock_path = "session/instance.lock";
/// Held as well so that an environment never shares a data root with a Host
/// process left running by an older build.
pub const legacy_lock_path = "session/host.lock";

const header = "cutrans_lifecycle=1";
const legacy_header = "cutrans_vm_host=1";

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

pub fn writeSnapshot(buffer: []u8, snapshot: Snapshot) ![]const u8 {
    return std.fmt.bufPrint(buffer, header ++ "\nstate={s}\nmode={s}\nboot_id={d}\nlast_shutdown_abnormal={d}\nabi={d}\ndocument={d}\npresent={d}\n", .{
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

/// Accepts the current header and the retired Host header with identical fields.
pub fn parseSnapshot(text: []const u8) !Snapshot {
    var result: Snapshot = .{};
    var header_seen = false;
    var seen: [7]bool = @splat(false);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, header) or std.mem.eql(u8, line, legacy_header)) {
            if (header_seen) return error.InvalidLifecycleRecord;
            header_seen = true;
            continue;
        }
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLifecycleRecord;
        const key = line[0..separator];
        const value = line[separator + 1 ..];
        const field = std.meta.stringToEnum(Field, key) orelse return error.InvalidLifecycleRecord;
        const index = @backingInt(field);
        if (seen[index]) return error.InvalidLifecycleRecord;
        seen[index] = true;
        switch (field) {
            .state => result.state = std.meta.stringToEnum(State, value) orelse return error.InvalidLifecycleRecord,
            .mode => result.mode = launch.parseMode(value) catch return error.InvalidLifecycleRecord,
            .boot_id => result.boot_id = std.fmt.parseInt(u64, value, 10) catch return error.InvalidLifecycleRecord,
            .last_shutdown_abnormal => {
                const flag = std.fmt.parseInt(u1, value, 10) catch return error.InvalidLifecycleRecord;
                result.last_shutdown_abnormal = flag != 0;
            },
            .abi => result.abi_version = std.fmt.parseInt(u32, value, 10) catch return error.InvalidLifecycleRecord,
            .document => result.document_fingerprint = std.fmt.parseInt(u64, value, 10) catch return error.InvalidLifecycleRecord,
            .present => result.present_count = std.fmt.parseInt(u64, value, 10) catch return error.InvalidLifecycleRecord,
        }
    }
    if (!header_seen or result.boot_id == 0 or result.abi_version == 0) return error.InvalidLifecycleRecord;
    for (seen) |present| if (!present) return error.InvalidLifecycleRecord;
    return result;
}

test "lifecycle record round trips and rejects duplicate fields" {
    var buffer: [max_record]u8 = undefined;
    const expected = Snapshot{
        .state = .running,
        .mode = .installed,
        .boot_id = 7,
        .last_shutdown_abnormal = true,
        .abi_version = 11,
        .document_fingerprint = 42,
        .present_count = 9,
    };
    const actual = try parseSnapshot(try writeSnapshot(&buffer, expected));
    try std.testing.expectEqualDeep(expected, actual);
    const duplicate = header ++ "\nstate=running\nstate=stopped\nmode=installed\nboot_id=7\nlast_shutdown_abnormal=1\nabi=7\ndocument=42\npresent=9\n";
    try std.testing.expectError(error.InvalidLifecycleRecord, parseSnapshot(duplicate));
}

test "the retired Host record is still readable for boot continuity" {
    const legacy = legacy_header ++ "\nstate=stopping\nmode=portable\nboot_id=3\nlast_shutdown_abnormal=0\nabi=11\ndocument=5\npresent=0\n";
    const parsed = try parseSnapshot(legacy);
    try std.testing.expectEqual(State.stopping, parsed.state);
    try std.testing.expectEqual(@as(u64, 3), parsed.boot_id);
}
