//! 进程树生命周期口岸;Job 是资源管理边界,不是安全沙箱

const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");

pub const Job = struct {
    handle: ?*anyopaque,
    process: ?*anyopaque = null,

    pub fn create() !Job {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        return .{ .handle = try windows.createJob() };
    }

    pub fn start(self: *Job, allocator: std.mem.Allocator, command_line: []const u8) !void {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (self.process != null) return error.ProcessAlreadyStarted;
        self.process = try windows.startProcess(self.handle, allocator, command_line);
    }

    pub fn wait(self: *Job) !u32 {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const process = self.process orelse return error.NoProcess;
        return windows.waitForProcess(process);
    }

    pub fn terminate(self: *Job) !void {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        try windows.terminateJob(self.handle);
    }

    pub fn deinit(self: *Job) void {
        if (self.process) |process| windows.closeHandle(process);
        if (self.handle) |handle| windows.closeHandle(handle);
        self.* = undefined;
    }
};

pub const Detached = struct {
    process: ?*anyopaque,

    pub fn start(allocator: std.mem.Allocator, command_line: []const u8) !Detached {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        return .{ .process = try windows.startDetachedProcess(allocator, command_line) };
    }

    pub fn startIn(allocator: std.mem.Allocator, command_line: []const u8, working_dir: []const u8) !Detached {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (!std.fs.path.isAbsolute(working_dir)) return error.AbsoluteWorkingDirectoryRequired;
        return .{ .process = try windows.startDetachedProcessIn(allocator, command_line, working_dir) };
    }

    pub fn wait(self: *Detached) !u32 {
        return windows.waitForProcess(self.process);
    }

    pub fn deinit(self: *Detached) void {
        windows.closeHandle(self.process);
        self.* = undefined;
    }
};

test "detached process can outlive the controller handle" {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var child = try Detached.start(std.testing.allocator, "cmd.exe /c exit 0");
    defer child.deinit();
    try std.testing.expectEqual(@as(u32, 0), try child.wait());
}

test "job waits for a real child process to exit successfully" {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var job = try Job.create();
    defer job.deinit();
    try job.start(std.testing.allocator, "cmd.exe /c exit 0");
    try std.testing.expectEqual(@as(u32, 0), try job.wait());
}

test "job termination stops a real long-lived child process" {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var job = try Job.create();
    defer job.deinit();
    try job.start(std.testing.allocator, "cmd.exe /c timeout /t 30 /nobreak");
    try job.terminate();
    try std.testing.expect((try job.wait()) != 0);
}

test "job ABI matches the pinned Windows SDK layout" {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (builtin.cpu.arch == .x86_64) {
        try std.testing.expectEqual(@as(usize, 64), windows.job_basic_limit_size);
        try std.testing.expectEqual(@as(usize, 144), windows.job_extended_limit_size);
    }
}
