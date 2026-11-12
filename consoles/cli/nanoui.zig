const std = @import("std");
const nanoui = @import("nanoui");
const vm_client = @import("vm_client");
const shell = @import("shell");

const ui = nanoui.ui;

const Job = struct {
    id: u64,
    attempt: u32 = 1,
    retry_of: ?u64 = null,
    cancel_requested: bool = false,
    state: []const u8,
    phase: []const u8,
    output: []const u8,
    error_text: []const u8,
    persistence_pending: bool = false,
};

const JobsPage = struct {
    items: []Job,
    next_after: ?u64 = null,
    active_count: usize = 0,
    record_pending: bool = false,
};

pub const State = struct {
    ctx: *vm_client.Context,
    input: ui.TextBuffer = .{},
    history: [16]?[]u8 = @splat(null),
    history_count: usize = 0,
    jobs: ?std.json.Parsed(JobsPage) = null,
    jobs_error: ?anyerror = null,
    after: u64 = 0,

    pub fn init(ctx: *vm_client.Context) State {
        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *State) void {
        self.input.deinit();
        for (self.history) |entry| if (entry) |text| self.ctx.allocator.free(text);
        self.history = @splat(null);
        if (self.jobs) |*jobs| jobs.deinit();
        self.jobs = null;
    }

    fn recordOwned(self: *State, text: []u8) void {
        const index = self.history_count % self.history.len;
        if (self.history[index]) |old| self.ctx.allocator.free(old);
        self.history[index] = text;
        self.history_count += 1;
    }

    fn record(self: *State, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.ctx.allocator, fmt, args) catch return;
        self.recordOwned(text);
    }

    fn unquote(value: []const u8) []const u8 {
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
        return value;
    }

    pub fn submitLine(self: *State) void {
        const line = std.mem.trim(u8, self.input.text(), " \t\r\n");
        if (line.len == 0 or line[0] == '#') return;
        const separator = std.mem.indexOfAny(u8, line, " \t");
        const name = if (separator) |at| line[0..at] else line;
        const arg = if (separator) |at| unquote(std.mem.trim(u8, line[at..], " \t")) else null;
        const result = self.ctx.command.dispatch(.{ .name = name, .arg = arg });
        self.record("{s} -> {s}", .{ line, result.codeText() });
        self.input.clear();
    }

    pub fn refreshJobs(self: *State) !void {
        const bytes = try shell.client.jobsRead(self.ctx.allocator, self.after);
        defer self.ctx.allocator.free(bytes);
        var next = try std.json.parseFromSlice(JobsPage, self.ctx.allocator, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        errdefer next.deinit();
        if (self.jobs) |*old| old.deinit();
        self.jobs = next;
        self.jobs_error = null;
    }

    fn refreshReport(self: *State) void {
        self.refreshJobs() catch |err| {
            self.jobs_error = err;
            self.ctx.status.set(@errorName(err));
        };
    }

    pub fn hasActiveWork(self: *const State) bool {
        return if (self.jobs) |jobs| jobs.value.active_count != 0 or jobs.value.record_pending else false;
    }

    fn cancel(self: *State, id: u64) void {
        var buffer: [32]u8 = undefined;
        const arg = std.fmt.bufPrint(&buffer, "{d}", .{id}) catch return;
        const result = self.ctx.command.dispatch(.{ .name = "task.cancel", .arg = arg });
        self.record("task.cancel {d} -> {s}", .{ id, result.codeText() });
        self.refreshReport();
    }

    fn retry(self: *State, id: u64) void {
        var buffer: [32]u8 = undefined;
        const arg = std.fmt.bufPrint(&buffer, "{d}", .{id}) catch return;
        const result = self.ctx.command.dispatch(.{ .name = "task.retry", .arg = arg });
        self.record("task.retry {d} -> {s}", .{ id, result.codeText() });
        self.refreshReport();
    }

    pub fn consoleView(self: *State, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(16), .gap = 12 });
        defer ui.end(c);
        ui.text(c, "CLI 控制台", .{ .size = 22, .weight = .bold });
        ui.label(c, "命令经同一 Runtime 注册表分派；accepted 只表示受理，不代表终态。");
        ui.row(c, .{ .width = .fill, .gap = 8 });
        {
            defer ui.end(c);
            const submitted = ui.textField(c, &self.input, .{ .placeholder = "例如 editor.invert.add 或 history.undo", .width = .fill });
            if (ui.button(c, "执行", .{ .variant = .primary }).clicked or submitted.submitted) self.submitLine();
        }
        ui.row(c, .{ .width = .fill, .gap = 8 });
        {
            defer ui.end(c);
            if (ui.button(c, "doc.read", .{}).clicked) {
                const result = self.ctx.command.dispatch(.{ .name = "doc.read" });
                self.record("doc.read -> {s}", .{result.codeText()});
            }
            if (ui.button(c, "task.list", .{}).clicked) {
                const result = self.ctx.command.dispatch(.{ .name = "task.list" });
                self.record("task.list -> {s}", .{result.codeText()});
            }
            if (ui.button(c, "library.list", .{}).clicked) {
                const result = self.ctx.command.dispatch(.{ .name = "library.list" });
                self.record("library.list -> {s}", .{result.codeText()});
            }
        }
        ui.divider(c);
        ui.text(c, "最近命令", .{ .weight = .semibold });
        if (self.history_count == 0) ui.text(c, "暂无命令记录", .{ .color = c.theme.muted });
        const shown = @min(self.history_count, self.history.len);
        for (0..shown) |offset| {
            const index = (self.history_count - shown + offset) % self.history.len;
            if (self.history[index]) |text| ui.text(c, text, .{ .mono = true, .wrap = true });
        }
    }

    fn jobRow(self: *State, c: *ui.Context, job: Job) void {
        ui.keyInt(c, job.id);
        ui.column(c, .{ .width = .fill, .padding = .all(10), .gap = 6, .background = c.theme.surface, .border = c.theme.border, .radius = 6 });
        defer ui.end(c);
        ui.textf(c, .{ .weight = .semibold }, "任务 {d} · attempt {d} · {s}/{s}", .{ job.id, job.attempt, job.state, job.phase });
        if (job.retry_of) |parent| ui.textf(c, .{ .color = c.theme.muted }, "retry_of={d}", .{parent});
        ui.text(c, job.output, .{ .color = c.theme.muted, .truncate = .middle });
        if (job.error_text.len > 0) ui.text(c, job.error_text, .{ .color = c.theme.danger, .wrap = true });
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        {
            defer ui.end(c);
            if (job.cancel_requested) ui.badge(c, "已请求取消", c.theme.accent);
            if (job.persistence_pending) ui.badge(c, "终态待保存", c.theme.danger);
            if (ui.button(c, "取消", .{}).clicked) self.cancel(job.id);
            if (std.mem.eql(u8, job.state, "failed") or std.mem.eql(u8, job.state, "cancelled") or std.mem.eql(u8, job.state, "interrupted")) {
                if (ui.button(c, "以原输入重试", .{}).clicked) self.retry(job.id);
            }
        }
    }

    pub fn jobsView(self: *State, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(16), .gap = 12 });
        defer ui.end(c);
        ui.text(c, "任务", .{ .size = 22, .weight = .bold });
        ui.label(c, "JobRecord 为真源；近期缓存只是投影。关闭 Shell 不停止 Host 作业。");
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        {
            defer ui.end(c);
            if (ui.button(c, "刷新任务", .{}).clicked) self.refreshReport();
            if (self.jobs) |jobs| {
                ui.textf(c, .{ .color = c.theme.muted }, "活跃 {d} · 本页 {d}", .{ jobs.value.active_count, jobs.value.items.len });
                if (jobs.value.record_pending) ui.badge(c, "有待保存终态", c.theme.danger);
                if (jobs.value.next_after) |after| {
                    if (jobs.value.items.len != 0 and ui.button(c, "下一页", .{}).clicked) {
                        self.after = after;
                        self.refreshReport();
                    }
                }
            }
        }
        if (self.jobs_error) |err| ui.textf(c, .{ .color = c.theme.danger }, "任务投影更新失败，保留上一份：{s}", .{@errorName(err)});
        ui.scroll(c, .{ .grow = 1, .width = .fill, .height = .fill, .gap = 10 });
        defer ui.end(c);
        if (self.jobs) |jobs| {
            for (jobs.value.items) |job| self.jobRow(c, job);
            if (jobs.value.items.len == 0) ui.text(c, "当前页没有任务记录。", .{ .color = c.theme.muted });
        } else {
            ui.text(c, "选择“刷新任务”读取 Host 作业页。", .{ .color = c.theme.muted });
        }
    }
};

test "job page projection preserves terminal and pending metadata" {
    const text = "{\"items\":[{\"id\":9,\"attempt\":2,\"retry_of\":8,\"cancel_requested\":true,\"state\":\"cancelled\",\"phase\":\"cancelled\",\"output\":\"exports/output.png\",\"error_text\":\"Cancelled\",\"persistence_pending\":true}],\"next_after\":9,\"active_count\":1,\"record_pending\":true}";
    var parsed = try std.json.parseFromSlice(JobsPage, std.testing.allocator, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.items.len);
    try std.testing.expectEqual(@as(?u64, 8), parsed.value.items[0].retry_of);
    try std.testing.expect(parsed.value.items[0].persistence_pending);
    try std.testing.expect(parsed.value.record_pending);
}
