const std = @import("std");

pub const ResultCode = enum(u8) {
    ok,
    accepted,
    unknown_command,
    invalid_arguments,
    permission_denied,
    invalid_state,
    not_ready,
    queue_full,
    failed,
    cancelled,
};

pub const Event = struct {
    serial: u64,
    time_ns: i64,
    expected_code: ResultCode,
    name: [64]u8,
    arg: [128]u8,
    name_len: u8,
    arg_len: u16,

    pub fn command(self: *const Event) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn argument(self: *const Event) []const u8 {
        return self.arg[0..self.arg_len];
    }
};

pub const Log = struct {
    events: [32]Event,
    count: usize,
};

fn field(rest: *[]const u8) ![]const u8 {
    const comma = std.mem.indexOfScalar(u8, rest.*, ',') orelse return error.InvalidReplayEvent;
    const result = rest.*[0..comma];
    rest.* = rest.*[comma + 1 ..];
    return result;
}

fn validatePathCommand(name: []const u8, arg: []const u8) !void {
    const path_command = std.mem.eql(u8, name, "doc.open") or
        std.mem.eql(u8, name, "doc.write") or
        std.mem.eql(u8, name, "doc.save") or
        std.mem.eql(u8, name, "editor.export.png") or
        std.mem.eql(u8, name, "editor.image.open");
    if (!path_command or arg.len == 0) return;
    _ = try @import("uri.zig").parse(arg);
}

pub fn parse(text: []const u8) !Log {
    var result: Log = .{ .events = std.mem.zeroes([32]Event), .count = 0 };
    var format_seen = false;
    var clock_seen = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "cutrans_replay=1")) {
            if (format_seen) return error.InvalidReplayLog;
            format_seen = true;
            continue;
        }
        if (std.mem.eql(u8, line, "clock=logical")) {
            if (clock_seen) return error.InvalidReplayLog;
            clock_seen = true;
            continue;
        }
        if (!std.mem.startsWith(u8, line, "event=")) return error.InvalidReplayEvent;
        if (result.count == result.events.len) return error.TooManyReplayEvents;
        var rest = line["event=".len..];
        const serial = try std.fmt.parseInt(u64, try field(&rest), 10);
        if (serial != result.count + 1) return error.InvalidReplaySerial;
        const time_ns = try std.fmt.parseInt(i64, try field(&rest), 10);
        if (result.count > 0 and time_ns < result.events[result.count - 1].time_ns) return error.ReplayTimeTravel;
        const expected_code = std.meta.stringToEnum(ResultCode, try field(&rest)) orelse return error.InvalidReplayResult;
        const name = try field(&rest);
        if (name.len == 0 or name.len > 64) return error.InvalidReplayCommand;
        const arg = rest;
        if (arg.len > 128) return error.InvalidReplayArgument;
        try validatePathCommand(name, arg);
        var event = Event{
            .serial = serial,
            .time_ns = time_ns,
            .expected_code = expected_code,
            .name = std.mem.zeroes([64]u8),
            .arg = std.mem.zeroes([128]u8),
            .name_len = @intCast(name.len),
            .arg_len = @intCast(arg.len),
        };
        @memcpy(event.name[0..name.len], name);
        @memcpy(event.arg[0..arg.len], arg);
        result.events[result.count] = event;
        result.count += 1;
    }
    if (!format_seen or !clock_seen or result.count == 0) return error.InvalidReplayLog;
    return result;
}

test "replay log validates logical time and VNE path arguments" {
    const text = "cutrans_replay=1\nclock=logical\nevent=1,10,ok,doc.open,\nevent=2,20,ok,doc.save,session://documents/a.cut\n";
    const log = try parse(text);
    try std.testing.expectEqual(@as(usize, 2), log.count);
    try std.testing.expectEqualStrings("doc.save", log.events[1].command());
    try std.testing.expectEqualStrings("session://documents/a.cut", log.events[1].argument());
    try std.testing.expectError(error.ReplayTimeTravel, parse("cutrans_replay=1\nclock=logical\nevent=1,20,ok,doc.open,\nevent=2,10,ok,doc.open,\n"));
    try std.testing.expectError(error.NotVirtualUri, parse("cutrans_replay=1\nclock=logical\nevent=1,10,ok,doc.open,C:/host/a.cut\n"));
    try std.testing.expectError(error.InvalidReplayResult, parse("cutrans_replay=1\nclock=logical\nevent=1,10,sometimes,doc.open,\n"));
}
