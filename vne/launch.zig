const std = @import("std");

pub const Mode = enum { development, portable, installed };
pub const Purpose = enum { normal, verification, diagnostic, replay };

pub fn parseMode(text: []const u8) !Mode {
    if (std.mem.eql(u8, text, "development")) return .development;
    if (std.mem.eql(u8, text, "portable")) return .portable;
    if (std.mem.eql(u8, text, "installed")) return .installed;
    return error.InvalidMode;
}

pub const LaunchOptions = struct {
    mode: Mode = .development,
    open_path: ?[]const u8 = null,
    mode_seen: bool = false,
    purpose: Purpose = .normal,
    purpose_seen: bool = false,
};

pub fn parseLaunchArg(options: *LaunchOptions, args: anytype, arg: []const u8) !bool {
    const purpose = if (std.mem.startsWith(u8, arg, "--purpose="))
        arg["--purpose=".len..]
    else if (std.mem.eql(u8, arg, "--purpose"))
        args.next() orelse return error.MissingPurpose
    else
        null;
    if (purpose) |value| {
        if (options.purpose_seen) return error.DuplicatePurpose;
        options.purpose = std.meta.stringToEnum(Purpose, value) orelse return error.InvalidPurpose;
        options.purpose_seen = true;
        return true;
    }
    var mode: ?[]const u8 = null;
    if (std.mem.startsWith(u8, arg, "--mode=")) {
        mode = arg["--mode=".len..];
    } else if (std.mem.eql(u8, arg, "--mode")) {
        mode = args.next() orelse return error.MissingMode;
    }
    if (mode) |value| {
        if (options.mode_seen) return error.DuplicateMode;
        options.mode = try parseMode(value);
        options.mode_seen = true;
        return true;
    }
    const path = if (std.mem.eql(u8, arg, "--open"))
        args.next() orelse return error.MissingOpenPath
    else if (std.mem.startsWith(u8, arg, "--open="))
        arg["--open=".len..]
    else
        return false;
    if (options.open_path != null) return error.DuplicateOpenPath;
    if (path.len == 0) return error.MissingOpenPath;
    options.open_path = path;
    return true;
}

pub fn parseLaunchArgs(args: anytype) !LaunchOptions {
    var options: LaunchOptions = .{};
    while (args.next()) |arg| {
        if (!try parseLaunchArg(&options, args, arg)) return error.InvalidArgument;
    }
    return options;
}

const TestArgs = struct {
    items: []const []const u8,
    index: usize = 0,

    fn next(self: *TestArgs) ?[]const u8 {
        if (self.index == self.items.len) return null;
        defer self.index += 1;
        return self.items[self.index];
    }
};

test "launch options accept both open forms and reject duplicate arguments" {
    var separate = TestArgs{ .items = &.{ "--mode=installed", "--open", "C:/work/a file.cut" } };
    const first = try parseLaunchArgs(&separate);
    try std.testing.expectEqual(Mode.installed, first.mode);
    try std.testing.expectEqualStrings("C:/work/a file.cut", first.open_path.?);
    var joined = TestArgs{ .items = &.{"--open=C:/work/b.cut"} };
    const second = try parseLaunchArgs(&joined);
    try std.testing.expectEqual(Mode.development, second.mode);
    try std.testing.expectEqualStrings("C:/work/b.cut", second.open_path.?);
    var duplicate_open = TestArgs{ .items = &.{ "--open=a.cut", "--open", "b.cut" } };
    try std.testing.expectError(error.DuplicateOpenPath, parseLaunchArgs(&duplicate_open));
    var duplicate_mode = TestArgs{ .items = &.{ "--mode", "development", "--mode=development" } };
    try std.testing.expectError(error.DuplicateMode, parseLaunchArgs(&duplicate_mode));
    var missing_path = TestArgs{ .items = &.{"--open"} };
    try std.testing.expectError(error.MissingOpenPath, parseLaunchArgs(&missing_path));
    var unknown = TestArgs{ .items = &.{"--unknown"} };
    try std.testing.expectError(error.InvalidArgument, parseLaunchArgs(&unknown));
}
