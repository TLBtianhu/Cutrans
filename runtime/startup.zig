//! startup.zig — 核心二进制自举:先整体验证,再按阶段执行 startup.ccb
//!
//! configure=字体/语言等宿主初始化前置配置;session=应用/操作台/固定入口。
//! CCB1 文件头 12B:magic/version/flags/record_count;记录 8B+payload。
//! 这里不读取 .ccmd;文本资源只能由已启动的 CLI 应用解析。

const std = @import("std");
const command = @import("command.zig");

pub const Phase = enum { configure, session, all };
pub const Report = struct { files: usize = 0, commands: usize = 0 };

fn u16At(data: []const u8, off: usize) u16 {
    return @as(u16, data[off]) | (@as(u16, data[off + 1]) << 8);
}
fn u32At(data: []const u8, off: usize) u32 {
    return @as(u32, data[off]) |
        (@as(u32, data[off + 1]) << 8) |
        (@as(u32, data[off + 2]) << 16) |
        (@as(u32, data[off + 3]) << 24);
}

fn commandName(opcode: u16) ![]const u8 {
    return switch (opcode) {
        1 => "console.cli.start",
        3 => "font.main",
        4 => "locale.default",
        5 => "cli.load",
        6 => "app.open",
        7 => "session.shell",
        8 => "taskbar.pin",
        else => error.UnknownStartupOpcode,
    };
}

fn phaseOf(name: []const u8) Phase {
    if (std.mem.eql(u8, name, "font.main") or std.mem.eql(u8, name, "locale.default")) return .configure;
    return .session;
}

fn validate(data: []const u8) !void {
    if (data.len < 12) return error.TruncatedHeader;
    if (!std.mem.eql(u8, data[0..4], "CCB1")) return error.BadMagic;
    if (u16At(data, 4) != 1) return error.UnsupportedVersion;
    if (u16At(data, 6) != 0) return error.UnsupportedFlags;
    const count = u32At(data, 8);
    var pos: usize = 12;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos + 8 > data.len) return error.TruncatedRecord;
        const opcode = u16At(data, pos);
        const flags = u16At(data, pos + 2);
        const arg_len: usize = @intCast(u32At(data, pos + 4));
        _ = try commandName(opcode);
        if (flags != 0) return error.UnsupportedFlags;
        pos += 8;
        if (arg_len > data.len - pos) return error.TruncatedArgument;
        pos += arg_len;
    }
    if (pos != data.len) return error.TrailingData;
}

pub fn executePhase(io: std.Io, allocator: std.mem.Allocator, registry: *command.Registry, phase: Phase) !Report {
    const exe_dir = try std.process.executableDirPathAlloc(io, allocator);
    const path = try std.fmt.allocPrint(allocator, "{s}/config/startup.ccb", .{exe_dir});
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    try validate(data);

    const count = u32At(data, 8);
    var pos: usize = 12;
    var report = Report{ .files = 1 };
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const opcode = u16At(data, pos);
        const arg_len: usize = @intCast(u32At(data, pos + 4));
        pos += 8;
        const name = try commandName(opcode);
        const arg = if (arg_len == 0) null else data[pos .. pos + arg_len];
        pos += arg_len;
        if (phase != .all and phase != phaseOf(name)) continue;
        if (registry.dispatch(.{ .name = name, .arg = arg }).code != .ok) return error.StartupCommandFailed;
        report.commands += 1;
    }
    return report;
}

pub fn execute(io: std.Io, allocator: std.mem.Allocator, registry: *command.Registry) !Report {
    return executePhase(io, allocator, registry, .all);
}

test "startup validation rejects unknown opcodes before dispatch" {
    var data = std.mem.zeroes([20]u8);
    @memcpy(data[0..4], "CCB1");
    data[4] = 1;
    data[8] = 1;
    data[12] = 99;
    try std.testing.expectError(error.UnknownStartupOpcode, validate(&data));
}

test "startup phases keep configuration separate from session activation" {
    try std.testing.expectEqual(Phase.configure, phaseOf("font.main"));
    try std.testing.expectEqual(Phase.configure, phaseOf("locale.default"));
    try std.testing.expectEqual(Phase.session, phaseOf("session.shell"));
    try std.testing.expectEqual(Phase.session, phaseOf("console.cli.start"));
    try std.testing.expectEqual(Phase.session, phaseOf("taskbar.pin"));
}
