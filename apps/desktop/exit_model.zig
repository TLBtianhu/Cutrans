const std = @import("std");
const nanoui = @import("nanoui");
const Control = @import("vne").environment_control.Control;

pub const Phase = enum { inactive, confirm, waiting, cancelling, ready, stopping, failed, stopped };

pub const State = struct {
    hooks: *Control,
    phase: Phase = .inactive,
    active_count: usize = 0,
    record_pending: bool = false,
    last_error: ?[]const u8 = null,

    pub fn active(self: *const State) bool {
        return self.phase != .inactive;
    }

    pub fn noteError(self: *State, err: anyerror) void {
        self.last_error = @errorName(err);
    }

    fn fail(self: *State, err: anyerror) void {
        self.noteError(err);
        self.phase = .failed;
    }

    fn readJobs(self: *State, jobs: anytype) void {
        if (jobs.jobs) |page| {
            self.active_count = page.value.active_count;
            self.record_pending = page.value.record_pending;
        }
    }

    pub fn begin(self: *State, library: anytype, jobs: anytype) !void {
        if (self.active()) return error.ExitAlreadyActive;
        self.last_error = null;
        if (library.work) |*work| if (!work.beforeClose()) return error.WorkEditPending;
        self.phase = .confirm;
        self.hooks.prepareStop() catch |err| {
            self.phase = .inactive;
            return err;
        };
        try jobs.refreshJobs();
        self.readJobs(jobs);
        self.phase = if (jobs.hasActiveWork()) .confirm else .ready;
        std.debug.print("CUTRANS_EXIT_PREPARED active={d} record_pending={d}\n", .{ self.active_count, @intFromBool(self.record_pending) });
    }

    pub fn waitForJobs(self: *State) !void {
        if (self.phase != .confirm) return error.InvalidExitState;
        self.phase = .waiting;
    }

    pub fn cancelJobs(self: *State) !void {
        if (self.phase != .confirm and self.phase != .waiting) return error.InvalidExitState;
        try self.hooks.cancelJobs();
        self.phase = .cancelling;
        std.debug.print("CUTRANS_EXIT_CANCEL_REQUESTED\n", .{});
    }

    pub fn resume_work(self: *State) !void {
        if (self.phase != .confirm and self.phase != .waiting and self.phase != .cancelling) return error.InvalidExitState;
        try self.hooks.resumeWork();
        self.phase = .inactive;
        self.last_error = null;
        std.debug.print("CUTRANS_EXIT_RESUME_OK\n", .{});
    }

    fn finish(self: *State) void {
        self.phase = .stopping;
        self.hooks.stopEnvironment() catch |err| {
            self.fail(err);
            return;
        };
        self.phase = .stopped;
    }

    pub fn retry(self: *State) void {
        if (self.phase != .failed) return;
        self.last_error = null;
        self.phase = .ready;
    }

    pub fn tick(self: *State, c: *nanoui.ui.Context, jobs: anytype) void {
        switch (self.phase) {
            .confirm, .waiting, .cancelling => {
                jobs.refreshJobs() catch |err| {
                    self.fail(err);
                    return;
                };
                self.readJobs(jobs);
                if (!jobs.hasActiveWork()) self.phase = .ready;
                c.frameIn(0.05);
            },
            .ready, .stopping => self.finish(),
            else => {},
        }
    }

    pub fn view(self: *State, c: *nanoui.ui.Context) void {
        const ui = nanoui.ui;
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(28), .gap = 14 });
        defer ui.end(c);
        ui.text(c, "退出虚拟环境", .{ .size = 26, .weight = .bold });
        ui.label(c, "这里会停止新业务、处理任务、保存文档，然后结束整个虚拟环境。");
        switch (self.phase) {
            .inactive => {},
            .confirm => {
                ui.textf(c, .{}, "仍有 {d} 个活动任务{s}", .{ self.active_count, if (self.record_pending) "，另有终态待保存" else "" });
                if (ui.button(c, "等待任务完成后退出", .{ .variant = .primary }).clicked) self.waitForJobs() catch |err| self.noteError(err);
                if (ui.button(c, "取消未完成并退出", .{}).clicked) self.cancelJobs() catch |err| self.noteError(err);
                if (ui.button(c, "返回环境", .{}).clicked) self.resume_work() catch |err| self.noteError(err);
            },
            .waiting, .cancelling => {
                ui.textf(c, .{}, "活动任务 {d} · 终态待保存 {d}", .{ self.active_count, @intFromBool(self.record_pending) });
                ui.label(c, if (self.phase == .waiting) "正在等待已有任务完成；不再接受新业务。" else "已请求协作取消；不会强制中断编码器或系统调用。");
                if (ui.button(c, "返回环境", .{}).clicked) self.resume_work() catch |err| self.noteError(err);
            },
            .ready, .stopping => ui.label(c, "正在保存文档、冲刷任务结果并结束虚拟环境…"),
            .failed => {
                ui.textf(c, .{ .color = c.theme.danger }, "安全退出未完成：{s}", .{self.last_error orelse "EnvironmentStopFailed"});
                ui.label(c, "环境仍在运行；修复原因后可重试。仅关闭窗口时下次启动会按异常结束恢复。");
                if (ui.button(c, "重试安全退出", .{ .variant = .primary }).clicked) self.retry();
                if (ui.button(c, "仅关闭窗口", .{}).clicked) c.close_request = true;
                c.changed = true;
            },
            .stopped => {
                ui.label(c, "环境已安全退出，正在关闭窗口…");
                c.close_request = true;
                c.changed = true;
            },
        }
        if (self.last_error) |err| ui.textf(c, .{ .color = c.theme.danger }, "{s}", .{err});
    }
};
