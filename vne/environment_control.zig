//! environment_control.zig — App 对所在虚拟环境的生命周期与作业查询入口
//!
//! 环境与 App 同处一个进程；这张表只是调用约定，不携带任何传输语义。
//! 安全退出顺序：prepareStop（停止受理新业务）→ 可选 cancelJobs → stop
//! （冲刷作业终态、保存文档、记录正常停止）。resumeWork 撤销尚未完成的退出。
const std = @import("std");

pub const Control = struct {
    context: *anyopaque,
    prepare_stop: *const fn (*anyopaque) anyerror!void,
    cancel_jobs: *const fn (*anyopaque) anyerror!void,
    resume_work: *const fn (*anyopaque) anyerror!void,
    stop: *const fn (*anyopaque) anyerror!void,
    /// Returns a newly allocated `cutrans-jobs` JSON page owned by `allocator`.
    jobs_read: *const fn (*anyopaque, std.mem.Allocator, u64) anyerror![]u8,
    /// Set once `stop` has persisted a normal environment stop.
    stopped: bool = false,

    pub fn prepareStop(self: *Control) !void {
        return self.prepare_stop(self.context);
    }

    pub fn cancelJobs(self: *Control) !void {
        return self.cancel_jobs(self.context);
    }

    pub fn resumeWork(self: *Control) !void {
        return self.resume_work(self.context);
    }

    pub fn stopEnvironment(self: *Control) !void {
        try self.stop(self.context);
        self.stopped = true;
    }

    pub fn jobsRead(self: *Control, allocator: std.mem.Allocator, after_id: u64) ![]u8 {
        return self.jobs_read(self.context, allocator, after_id);
    }
};

const Fake = struct {
    calls: [5]usize = @splat(0),
    fail_stop: bool = false,

    fn self(ptr: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ptr));
    }
    fn prepare(ptr: *anyopaque) anyerror!void {
        self(ptr).calls[0] += 1;
    }
    fn cancel(ptr: *anyopaque) anyerror!void {
        self(ptr).calls[1] += 1;
    }
    fn resumeFn(ptr: *anyopaque) anyerror!void {
        self(ptr).calls[2] += 1;
    }
    fn stopFn(ptr: *anyopaque) anyerror!void {
        self(ptr).calls[3] += 1;
        if (self(ptr).fail_stop) return error.SaveFailed;
    }
    fn jobs(ptr: *anyopaque, allocator: std.mem.Allocator, after: u64) anyerror![]u8 {
        self(ptr).calls[4] += 1;
        return std.fmt.allocPrint(allocator, "{{\"after\":{d}}}", .{after});
    }
};

test "stopped is only set after a successful stop" {
    var fake: Fake = .{ .fail_stop = true };
    var control = Control{ .context = &fake, .prepare_stop = Fake.prepare, .cancel_jobs = Fake.cancel, .resume_work = Fake.resumeFn, .stop = Fake.stopFn, .jobs_read = Fake.jobs };
    try control.prepareStop();
    try std.testing.expectError(error.SaveFailed, control.stopEnvironment());
    try std.testing.expect(!control.stopped);
    fake.fail_stop = false;
    try control.stopEnvironment();
    try std.testing.expect(control.stopped);
    const page = try control.jobsRead(std.testing.allocator, 4);
    defer std.testing.allocator.free(page);
    try std.testing.expectEqualStrings("{\"after\":4}", page);
}
