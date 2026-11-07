const std = @import("std");

pub const Kind = enum(u8) { pointer_move, pointer_down, pointer_up, key_down, key_up, text, focus };
pub const Action = enum(u8) { none, release, press, repeat };
pub const Context = struct {
    pub const text_input: u32 = 1;
    pub const editing_unavailable: u32 = 2;
};

pub const Event = struct {
    serial: u64,
    time_ns: i64,
    kind: Kind,
    action: Action = .none,
    code: u16 = 0,
    mods: u8 = 0,
    context: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    text: [64]u8 = std.mem.zeroes([64]u8),
    text_len: u16 = 0,

    pub fn textValue(self: *const Event) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn validate(self: *const Event) !void {
        if (self.text_len > self.text.len) return error.InvalidInputTextLength;
        if (self.mods & 0xf0 != 0) return error.InvalidInputModifiers;
        if (self.context & ~@as(u32, Context.text_input | Context.editing_unavailable) != 0) return error.InvalidInputContext;
        if (self.kind != .text and self.text_len != 0) return error.InvalidInputPayload;
        switch (self.kind) {
            .pointer_move => if (self.action != .none or self.code != 0 or self.mods != 0) return error.InvalidInputPayload,
            .pointer_down, .pointer_up => {
                const expected: Action = if (self.kind == .pointer_down) .press else .release;
                if (self.action != expected or self.code > 8) return error.InvalidInputPayload;
            },
            .key_down => if ((self.action != .press and self.action != .repeat)) return error.InvalidInputAction,
            .key_up => if (self.action != .release) return error.InvalidInputAction,
            .text => if (self.text_len == 0 or !std.unicode.utf8ValidateSlice(self.textValue()) or self.action != .none or self.code != 0 or self.mods != 0 or self.x != 0 or self.y != 0) return error.InvalidInputText,
            .focus => if ((self.x != 0 and self.x != 1) or self.y != 0 or self.action != .none or self.code != 0 or self.mods != 0) return error.InvalidInputPayload,
        }
    }
};

pub const Queue = struct {
    events: [32]Event = undefined,
    start: usize = 0,
    count: usize = 0,
    last_serial: u64 = 0,
    last_time_ns: i64 = 0,
    consumed_count: u64 = 0,
    last_consumed: ?Event = null,

    pub fn reset(self: *Queue) void {
        self.* = .{};
    }

    pub fn push(self: *Queue, event: Event) !void {
        if (event.serial != self.last_serial + 1) return error.InvalidInputSerial;
        if (event.time_ns < self.last_time_ns) return error.InputTimeTravel;
        try event.validate();
        if (self.count == self.events.len) return error.InputQueueFull;
        const index = (self.start + self.count) % self.events.len;
        self.events[index] = event;
        self.count += 1;
        self.last_serial = event.serial;
        self.last_time_ns = event.time_ns;
    }

    pub fn next(self: *Queue) ?Event {
        if (self.count == 0) return null;
        const event = self.events[self.start];
        self.start = (self.start + 1) % self.events.len;
        self.count -= 1;
        self.consumed_count += 1;
        self.last_consumed = event;
        return event;
    }

    pub fn last(self: *const Queue) ?Event {
        if (self.count == 0) return null;
        return self.events[(self.start + self.count - 1) % self.events.len];
    }
};

test "semantic input preserves text focus and order without OS events" {
    var queue: Queue = .{};
    try queue.push(.{ .serial = 1, .time_ns = 10, .kind = .pointer_move, .x = 12, .y = 24 });
    const text = "你好";
    var event = Event{ .serial = 2, .time_ns = 20, .kind = .text };
    @memcpy(event.text[0..text.len], text);
    event.text_len = text.len;
    try queue.push(event);
    try std.testing.expectEqualStrings(text, queue.last().?.textValue());
    try std.testing.expectEqual(Kind.pointer_move, queue.next().?.kind);
    try std.testing.expectEqual(Kind.text, queue.next().?.kind);
    try std.testing.expect(queue.next() == null);
    try std.testing.expectError(error.InputTimeTravel, queue.push(.{ .serial = 3, .time_ns = 19, .kind = .focus, .x = 1 }));
}

test "semantic input rejects a text length beyond its inline storage" {
    var queue: Queue = .{};
    try std.testing.expectError(error.InvalidInputTextLength, queue.push(.{ .serial = 1, .time_ns = 10, .kind = .text, .text_len = 65 }));
    try queue.push(.{ .serial = 1, .time_ns = 10, .kind = .focus, .x = 1 });
    try std.testing.expectEqual(@as(usize, 1), queue.count);
}
