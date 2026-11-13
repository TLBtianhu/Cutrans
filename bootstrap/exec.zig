//! exec.zig — 无窗口前端：在真实环境实例里逐行执行 JSON 调用脚本
//!
//! 取代旧的 Host start/attach/stop 驱动方式，供调试与验证脚本使用。每行一个
//! JSON 对象，`call` 指定动作；每个动作输出一行 `CUTRANS_EXEC {json}`。
//! 调用形状刻意接近 tool call（名称 + 参数），将来可直接接 MCP 的 stdio 边缘。
//!
//! | call        | 字段                               | 作用 |
//! | ---         | ---                                | --- |
//! | `command`   | `name`，可选 `arg`、`expect`       | 执行 VM 命令；给了 `expect` 时状态不符即失败 |
//! | `document`  |                                    | 输出文档指纹与规范文本 |
//! | `jobs`      | 可选 `after`                       | 输出一页作业 JSON |
//! | `wait_jobs` | 可选 `timeout_ms`（默认 30000）    | 等到没有活动作业且终态已落盘 |
//! | `prepare_stop` / `cancel_jobs` / `resume_work` |      | 安全退出的分步动作，与桌面“退出虚拟环境…”同一入口 |
//! | `stop`      |                                    | 安全退出（冲刷、保存、记录正常停止）；必须是最后一行 |
//! | `crash`     |                                    | 不做任何收尾直接结束进程，用于异常结束验证 |
//!
//! 脚本结束而没有 `stop` 时，入口照常执行正常停止。
const std = @import("std");
const abi = @import("vne").abi;
const Control = @import("vne").environment_control.Control;

const max_script = 1024 * 1024;
const max_document = 4 * 1024 * 1024;

fn emit(allocator: std.mem.Allocator, value: anytype) !void {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(text);
    std.debug.print("CUTRANS_EXEC {s}\n", .{text});
}

fn field(object: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    return object.get(name);
}

fn stringField(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = field(object, name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidExecField,
    };
}

fn intField(object: std.json.ObjectMap, name: []const u8) !?i64 {
    const value = field(object, name) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => error.InvalidExecField,
    };
}

fn bytes(value: []const u8) abi.ByteSlice {
    return .{ .ptr = value.ptr, .len = value.len };
}

fn readDocument(allocator: std.mem.Allocator, shell_api: *const abi.ShellApi) ![]u8 {
    var required: usize = 0;
    const query = shell_api.document_read(shell_api.context, null, 0, &required);
    if (query != abi.Status.buffer_too_small and query != abi.Status.ok) return error.DocumentReadFailed;
    if (required == 0 or required > max_document) return error.DocumentReadFailed;
    const buffer = try allocator.alloc(u8, required);
    errdefer allocator.free(buffer);
    var actual: usize = 0;
    if (shell_api.document_read(shell_api.context, buffer.ptr, buffer.len, &actual) != abi.Status.ok or actual > buffer.len) return error.DocumentReadFailed;
    return allocator.realloc(buffer, actual);
}

const JobsSummary = struct {
    active_count: usize = 0,
    record_pending: bool = false,
};

fn waitJobs(allocator: std.mem.Allocator, io: std.Io, control: *Control, timeout_ms: i64) !JobsSummary {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms }, .clock = .awake });
    while (true) {
        const page = try control.jobsRead(allocator, 0);
        defer allocator.free(page);
        const parsed = try std.json.parseFromSlice(JobsSummary, allocator, page, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (parsed.value.active_count == 0 and !parsed.value.record_pending) return parsed.value;
        if (std.Io.Clock.Timestamp.compare(.now(io, .awake), .gte, deadline)) return error.ExecJobsTimeout;
        try std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake);
    }
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, path: []const u8, shell_api: *const abi.ShellApi, control: *Control) !void {
    const script = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_script));
    defer allocator.free(script);
    var lines = std.mem.splitScalar(u8, script, '\n');
    var number: usize = 0;
    var stopped = false;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (stopped) return error.ExecLineAfterStop;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidExecLine;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidExecLine,
        };
        const call = (try stringField(object, "call")) orelse return error.MissingExecCall;
        if (std.mem.eql(u8, call, "command")) {
            const name = (try stringField(object, "name")) orelse return error.MissingExecName;
            const arg = try stringField(object, "arg");
            var task_id: u64 = 0;
            const status = shell_api.command_result(shell_api.context, bytes(name), if (arg) |value| bytes(value) else .{}, &task_id);
            try emit(allocator, .{ .line = number, .call = call, .name = name, .status = status, .task = task_id });
            if (try intField(object, "expect")) |expected| {
                if (expected != status) return error.ExecExpectationFailed;
            }
        } else if (std.mem.eql(u8, call, "document")) {
            var value: u64 = 0;
            if (shell_api.document_fingerprint(shell_api.context, &value) != abi.Status.ok) return error.DocumentReadFailed;
            const text = try readDocument(allocator, shell_api);
            defer allocator.free(text);
            try emit(allocator, .{ .line = number, .call = call, .fingerprint = value, .text = text });
        } else if (std.mem.eql(u8, call, "jobs")) {
            const after = (try intField(object, "after")) orelse 0;
            if (after < 0) return error.InvalidExecField;
            const page = try control.jobsRead(allocator, @intCast(after));
            defer allocator.free(page);
            std.debug.print("CUTRANS_EXEC {{\"line\":{d},\"call\":\"jobs\",\"page\":{s}}}\n", .{ number, page });
        } else if (std.mem.eql(u8, call, "wait_jobs")) {
            const timeout = (try intField(object, "timeout_ms")) orelse 30000;
            if (timeout <= 0) return error.InvalidExecField;
            const summary = try waitJobs(allocator, io, control, timeout);
            try emit(allocator, .{ .line = number, .call = call, .active_count = summary.active_count, .record_pending = summary.record_pending });
        } else if (std.mem.eql(u8, call, "prepare_stop") or std.mem.eql(u8, call, "cancel_jobs") or std.mem.eql(u8, call, "resume_work")) {
            const result = if (std.mem.eql(u8, call, "prepare_stop"))
                control.prepareStop()
            else if (std.mem.eql(u8, call, "cancel_jobs"))
                control.cancelJobs()
            else
                control.resumeWork();
            result catch |err| {
                try emit(allocator, .{ .line = number, .call = call, .ok = false, .@"error" = @errorName(err) });
                return err;
            };
            try emit(allocator, .{ .line = number, .call = call, .ok = true });
        } else if (std.mem.eql(u8, call, "stop")) {
            try control.prepareStop();
            try control.stopEnvironment();
            try emit(allocator, .{ .line = number, .call = call, .stopped = true });
            stopped = true;
        } else if (std.mem.eql(u8, call, "crash")) {
            try emit(allocator, .{ .line = number, .call = call });
            std.process.exit(70);
        } else return error.UnknownExecCall;
    }
}
