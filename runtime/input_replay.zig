const std = @import("std");
const vne = @import("vne");
const RuntimeContext = @import("context.zig").Context;
const command = @import("command.zig");
const input_actions = @import("input_actions.zig");

pub const ExpectedAction = struct {
    serial: u64,
    command: []const u8,
    result: ?command.Code,
    suppressed: bool,
};

pub const Expectation = struct {
    document_fingerprint: u64,
    history_count: u64,
    history_cursor: u64,
};

pub const Log = struct {
    version: u32,
    baseline_fingerprint: ?u64,
    events: []vne.input.Event,
    actions: []ExpectedAction,
    expected: ?Expectation,

    pub fn deinit(self: *Log, allocator: std.mem.Allocator) void {
        allocator.free(self.events);
        allocator.free(self.actions);
        self.* = undefined;
    }
};

const Fields = struct {
    values: [10][]const u8,
    count: usize,

    fn parse(rest: []const u8, expected: usize) !Fields {
        var result: Fields = .{ .values = undefined, .count = 0 };
        var parts = std.mem.splitScalar(u8, rest, ',');
        while (parts.next()) |part| {
            if (result.count == expected) return error.InvalidInputEvent;
            result.values[result.count] = part;
            result.count += 1;
        }
        if (result.count != expected) return error.InvalidInputEvent;
        return result;
    }
};

fn parseEvent(fields: Fields, serial: u64, time_ns: i64, version: u32) !vne.input.Event {
    const kind = std.meta.stringToEnum(vne.input.Kind, fields.values[2]) orelse return error.InvalidInputKind;
    const action = if (version == 1)
        switch (kind) {
            .pointer_down, .key_down => vne.input.Action.press,
            .pointer_up, .key_up => vne.input.Action.release,
            else => vne.input.Action.none,
        }
    else
        std.enums.fromInt(vne.input.Action, try std.fmt.parseInt(u8, fields.values[3], 10)) orelse return error.InvalidInputAction;
    const payload = if (version == 1) fields.values[5] else if (version == 2) fields.values[8] else fields.values[9];
    if (kind == .text) {
        if (payload.len == 0 or (version == 1 and payload.len > 64) or (version >= 2 and (payload.len > 128 or payload.len % 2 != 0))) return error.InvalidInputText;
    } else if (payload.len != 0) return error.InvalidInputPayload;
    var event = vne.input.Event{
        .serial = serial,
        .time_ns = time_ns,
        .kind = kind,
        .action = action,
        .code = if (version == 1) 0 else try std.fmt.parseInt(u16, fields.values[4], 10),
        .mods = if (version == 1) 0 else try std.fmt.parseInt(u8, fields.values[5], 10),
        .context = if (version < 3) 0 else try std.fmt.parseInt(u32, fields.values[6], 10),
        .x = try std.fmt.parseInt(i32, fields.values[if (version == 1) 3 else if (version == 2) 6 else 7], 10),
        .y = try std.fmt.parseInt(i32, fields.values[if (version == 1) 4 else if (version == 2) 7 else 8], 10),
    };
    if (kind == .text) {
        const text_len = if (version == 1) payload.len else payload.len / 2;
        if (version == 1) {
            @memcpy(event.text[0..text_len], payload);
        } else {
            _ = std.fmt.hexToBytes(event.text[0..text_len], payload) catch return error.InvalidInputText;
        }
        event.text_len = @intCast(text_len);
    }
    try event.validate();
    return event;
}

fn parseAction(fields: Fields, event_count: usize) !ExpectedAction {
    const serial = try std.fmt.parseInt(u64, fields.values[0], 10);
    if (serial == 0 or serial != event_count) return error.InvalidInputAction;
    if (fields.values[1].len == 0) return error.InvalidInputAction;
    const suppressed = std.mem.eql(u8, fields.values[2], "suppressed");
    return .{
        .serial = serial,
        .command = fields.values[1],
        .result = if (suppressed) null else std.meta.stringToEnum(command.Code, fields.values[2]) orelse return error.InvalidInputAction,
        .suppressed = suppressed,
    };
}

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Log {
    var events: std.ArrayList(vne.input.Event) = .empty;
    errdefer events.deinit(allocator);
    var actions: std.ArrayList(ExpectedAction) = .empty;
    errdefer actions.deinit(allocator);
    var version: ?u32 = null;
    var baseline_fingerprint: ?u64 = null;
    var expected: ?Expectation = null;
    var clock_seen = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const header = "cutrans_input_replay=";
        if (std.mem.startsWith(u8, line, header)) {
            if (version != null or line.len != header.len + 1 or line[line.len - 1] < '1' or line[line.len - 1] > '3') return error.InvalidInputReplayLog;
            version = line[line.len - 1] - '0';
            continue;
        }
        if (std.mem.eql(u8, line, "clock=logical")) {
            if (clock_seen) return error.InvalidInputReplayLog;
            clock_seen = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "baseline=")) {
            if (version == null or version.? != 3 or baseline_fingerprint != null) return error.InvalidInputReplayLog;
            baseline_fingerprint = try std.fmt.parseInt(u64, line["baseline=".len..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, line, "expect=")) {
            if (version == null or version.? != 3 or expected != null) return error.InvalidInputReplayLog;
            const fields = try Fields.parse(line["expect=".len..], 3);
            expected = .{
                .document_fingerprint = try std.fmt.parseInt(u64, fields.values[0], 10),
                .history_count = try std.fmt.parseInt(u64, fields.values[1], 10),
                .history_cursor = try std.fmt.parseInt(u64, fields.values[2], 10),
            };
            continue;
        }
        if (std.mem.startsWith(u8, line, "action=")) {
            if (version == null or version.? != 3 or events.items.len == 0) return error.InvalidInputAction;
            try actions.append(allocator, try parseAction(try Fields.parse(line["action=".len..], 3), events.items.len));
            continue;
        }
        if (!std.mem.startsWith(u8, line, "event=")) return error.InvalidInputEvent;
        if (version == null) return error.InvalidInputReplayLog;
        const fields = try Fields.parse(line["event=".len..], if (version.? == 1) 6 else if (version.? == 2) 9 else 10);
        const serial = try std.fmt.parseInt(u64, fields.values[0], 10);
        if (serial != events.items.len + 1) return error.InvalidInputSerial;
        const time_ns = try std.fmt.parseInt(i64, fields.values[1], 10);
        if (events.items.len > 0 and time_ns < events.items[events.items.len - 1].time_ns) return error.InputTimeTravel;
        try events.append(allocator, try parseEvent(fields, serial, time_ns, version.?));
    }
    if (version == null or !clock_seen or events.items.len == 0) return error.InvalidInputReplayLog;
    if (version.? == 3 and (baseline_fingerprint == null or expected == null)) return error.InvalidInputReplayLog;
    return .{
        .version = version.?,
        .baseline_fingerprint = baseline_fingerprint,
        .events = try events.toOwnedSlice(allocator),
        .actions = try actions.toOwnedSlice(allocator),
        .expected = expected,
    };
}

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

pub fn appendEvent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, event: *const vne.input.Event, time_ns: i64) !void {
    try event.validate();
    try appendFmt(out, allocator, "event={d},{d},{s},{d},{d},{d},{d},{d},{d},", .{
        event.serial,
        time_ns,
        @tagName(event.kind),
        @backingInt(event.action),
        event.code,
        event.mods,
        event.context,
        event.x,
        event.y,
    });
    if (event.kind == .text) {
        const digits = "0123456789abcdef";
        for (event.textValue()) |byte| {
            try out.append(allocator, digits[byte >> 4]);
            try out.append(allocator, digits[byte & 15]);
        }
    }
    try out.append(allocator, '\n');
}

pub fn appendAction(out: *std.ArrayList(u8), allocator: std.mem.Allocator, serial: u64, outcome: input_actions.Outcome) !void {
    const name = outcome.command orelse return;
    if (outcome.suppressed) {
        try appendFmt(out, allocator, "action={d},{s},suppressed\n", .{ serial, name });
    } else {
        try appendFmt(out, allocator, "action={d},{s},{s}\n", .{ serial, name, @tagName(outcome.result orelse return error.InvalidActionOutcome) });
    }
}

pub fn appendExpectation(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ctx: *const RuntimeContext) !void {
    try appendFmt(out, allocator, "expect={d},{d},{d}\n", .{ ctx.document.fingerprint(), ctx.history.count, ctx.history.cursor });
}

test "replay rejects a changed allocator baseline before consuming input" {
    var ctx: RuntimeContext = undefined;
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    const fingerprint = ctx.document.fingerprint();
    const text = try std.fmt.allocPrint(std.testing.allocator, "cutrans_input_replay=3\nclock=logical\nbaseline={d}\nevent=1,0,focus,0,0,0,0,1,0,\nexpect={d},0,0\n", .{ fingerprint, fingerprint });
    defer std.testing.allocator.free(text);
    var log = try parse(std.testing.allocator, text);
    defer log.deinit(std.testing.allocator);
    ctx.document.observeNodeId(9);
    try std.testing.expectError(error.InputBaselineMismatch, run(&ctx, &log));
    try std.testing.expectEqual(@as(u64, 0), ctx.devices.input.last_serial);
    try std.testing.expect(ctx.clock == .system);
}

pub fn run(ctx: *RuntimeContext, log: *const Log) !vne.abi.ReplayReport {
    if (ctx.devices.input.last_serial != 0 or ctx.history.count != 0 or ctx.tasks.count != 0) return error.ReplayRequiresFreshSession;
    if (log.version == 3 and ctx.document.fingerprint() != log.baseline_fingerprint.?) return error.InputBaselineMismatch;
    if (log.version == 3 and ctx.document.nodeIdHighWater() != @import("documents.zig").Document.initDefault().nodeIdHighWater()) return error.InputBaselineMismatch;
    ctx.clock = .{ .manual = .{} };
    var action_index: usize = 0;
    for (log.events) |*event| {
        try ctx.clock.advanceTo(event.time_ns);
        try ctx.devices.input.push(event.*);
        _ = ctx.devices.input.next().?;
        if (log.version < 3) continue;
        const actual = input_actions.dispatch(ctx, event);
        if (action_index < log.actions.len and log.actions[action_index].serial == event.serial) {
            const expected = log.actions[action_index];
            const command_matches = if (actual.command) |name| std.mem.eql(u8, name, expected.command) else false;
            if (!command_matches or actual.suppressed != expected.suppressed or actual.result != expected.result) {
                std.debug.print("[input-replay] event={d} action mismatch\n", .{event.serial});
                return error.InputActionMismatch;
            }
            action_index += 1;
        } else if (actual.command != null) {
            std.debug.print("[input-replay] event={d} unexpected action\n", .{event.serial});
            return error.InputActionMismatch;
        }
    }
    if (action_index != log.actions.len) return error.InputActionMismatch;
    const fingerprint = ctx.document.fingerprint();
    if (log.expected) |expected| {
        if (fingerprint != expected.document_fingerprint or ctx.history.count != expected.history_count or ctx.history.cursor != expected.history_cursor) {
            std.debug.print("[input-replay] state expected={d}/{d}/{d} actual={d}/{d}/{d}\n", .{
                expected.document_fingerprint,
                expected.history_count,
                expected.history_cursor,
                fingerprint,
                ctx.history.count,
                ctx.history.cursor,
            });
            return error.InputResultMismatch;
        }
    }
    return .{
        .struct_size = @sizeOf(vne.abi.ReplayReport),
        .abi_version = vne.abi.version,
        .kind = 1,
        .document_fingerprint = fingerprint,
        .history_count = @intCast(ctx.history.count),
        .history_cursor = @intCast(ctx.history.cursor),
        .task_count = 0,
        .tasks_hash = 14695981039346656037,
        .time_ns = try ctx.clock.now(),
        .event_count = @intCast(log.events.len),
        .input_events = @intCast(log.events.len),
    };
}

pub fn runUri(ctx: *RuntimeContext, path: []const u8) !vne.abi.ReplayReport {
    const parsed = try vne.uri.parse(path);
    const resolved = try ctx.mounts.resolveAlloc(ctx.allocator, parsed);
    defer ctx.allocator.free(resolved.path);
    const io = ctx.io orelse return error.IoNotReady;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, resolved.path, ctx.allocator, .limited(16 * 1024 * 1024));
    defer ctx.allocator.free(text);
    var log = try parse(ctx.allocator, text);
    defer log.deinit(ctx.allocator);
    return run(ctx, &log);
}

test "semantic input replay advances clock and yields ordered device events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const examples = try std.fs.path.join(std.testing.allocator, &.{ resource, "assets/examples" });
    defer std.testing.allocator.free(examples);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, examples);
    const minimal = try std.fs.path.join(std.testing.allocator, &.{ examples, "minimal.cut" });
    defer std.testing.allocator.free(minimal);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = minimal, .data = @import("assets").minimal_cut });
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ examples, "input.cvr" });
    defer std.testing.allocator.free(input_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = input_path, .data = @import("assets").input_replay_log });
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    var ctx: RuntimeContext = undefined;
    try @import("replay.zig").fixture(&ctx, std.testing.allocator, resource, data);
    defer ctx.deinit();
    const report = try runUri(&ctx, "pack://assets/examples/input.cvr");
    try std.testing.expectEqual(@as(u32, 1), report.kind);
    try std.testing.expectEqual(@as(i64, 5000000), report.time_ns);
    try std.testing.expectEqual(@as(u64, 5), report.input_events);
    try std.testing.expectEqual(vne.input.Kind.focus, ctx.devices.input.last_consumed.?.kind);
    try std.testing.expectEqual(@as(usize, 0), ctx.devices.input.count);
    try std.testing.expectEqual(@as(u64, 5), ctx.devices.input.consumed_count);
}

test "input replay v3 preserves context and arbitrary UTF-8 beyond the queue bound" {
    const initial = @import("documents.zig").Document.initDefault().fingerprint();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try appendFmt(&text, std.testing.allocator, "cutrans_input_replay=3\nclock=logical\nbaseline={d}\n", .{initial});
    for (0..40) |index| {
        const event = vne.input.Event{ .serial = @intCast(index + 1), .time_ns = @intCast(index), .kind = .focus, .x = 1 };
        try appendEvent(&text, std.testing.allocator, &event, @intCast(index));
    }
    const sample = "你\n好,Cutrans";
    var input = vne.input.Event{ .serial = 41, .time_ns = 41, .kind = .key_down, .action = .repeat, .code = 257, .mods = 3, .context = vne.input.Context.text_input };
    try appendEvent(&text, std.testing.allocator, &input, 41);
    input = .{ .serial = 42, .time_ns = 42, .kind = .text };
    @memcpy(input.text[0..sample.len], sample);
    input.text_len = sample.len;
    try appendEvent(&text, std.testing.allocator, &input, 42);
    try appendFmt(&text, std.testing.allocator, "expect={d},0,0\n", .{initial});
    var log = try parse(std.testing.allocator, text.items);
    defer log.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 42), log.events.len);
    try std.testing.expectEqual(vne.input.Action.repeat, log.events[40].action);
    try std.testing.expectEqual(@as(u16, 257), log.events[40].code);
    try std.testing.expectEqual(@as(u8, 3), log.events[40].mods);
    try std.testing.expectEqual(vne.input.Context.text_input, log.events[40].context);
    try std.testing.expectEqualStrings(sample, log.events[41].textValue());
}
