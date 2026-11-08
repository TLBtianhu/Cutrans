//! NanoUI text adapter. It owns history, never storage or clipboard IO.
const std = @import("std");
const ui = @import("nanoui").ui;
const history_mod = @import("text_history.zig");

pub const max_text_bytes = 1024 * 1024;
pub const Result = struct { changed: bool, focused: bool, composing: bool };
pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: ui.TextBuffer = .{},
    history: history_mod.History,
    pending_paste: ?[]u8 = null,
    composing: bool = false,
    pending_change: bool = false,
    selection: [2]usize,

    pub fn init(allocator: std.mem.Allocator, body: []const u8) !Editor {
        try validate(body);
        var history = try history_mod.History.init(allocator, body);
        errdefer history.deinit();
        var buffer: ui.TextBuffer = .{};
        errdefer buffer.deinit();
        try buffer.buf.ensureTotalCapacity(std.heap.c_allocator, body.len);
        buffer.buf.appendSliceAssumeCapacity(body);
        buffer.want_caret = body.len;
        return .{ .allocator = allocator, .buffer = buffer, .history = history, .selection = .{ body.len, body.len } };
    }
    pub fn deinit(self: *Editor) void {
        if (self.pending_paste) |pending| self.allocator.free(pending);
        self.history.deinit();
        self.buffer.deinit();
        self.* = undefined;
    }
    pub fn text(self: *const Editor) []const u8 {
        return self.buffer.text();
    }
    pub fn focus(self: *Editor) void {
        self.buffer.focus();
    }
    pub fn isComposing(self: *const Editor) bool {
        return self.composing;
    }
    pub fn canUndo(self: *const Editor) bool {
        return !self.composing and self.history.canUndo();
    }
    pub fn canRedo(self: *const Editor) bool {
        return !self.composing and self.history.canRedo();
    }
    pub fn undo(self: *Editor) !bool {
        if (self.composing) return error.CompositionActive;
        const snapshot = self.history.previous() orelse return false;
        try self.restore(snapshot);
        self.history.cursor -= 1;
        self.pending_change = true;
        return true;
    }
    pub fn redo(self: *Editor) !bool {
        if (self.composing) return error.CompositionActive;
        const snapshot = self.history.next() orelse return false;
        try self.restore(snapshot);
        self.history.cursor += 1;
        self.pending_change = true;
        return true;
    }
    fn restore(self: *Editor, snapshot: *const history_mod.Snapshot) !void {
        try self.buffer.buf.ensureTotalCapacity(std.heap.c_allocator, snapshot.text.len);
        self.buffer.buf.items.len = snapshot.text.len;
        @memcpy(self.buffer.buf.items, snapshot.text);
        self.selection = snapshot.selection;
        self.buffer.want_selection = snapshot.selection;
        self.buffer.want_caret = null;
    }
    pub fn paste(self: *Editor, source: []const u8) !void {
        try validate(source);
        if (self.composing) return error.CompositionActive;
        if (self.pending_paste != null) return error.PastePending;
        const normalized = try self.allocator.alloc(u8, source.len);
        errdefer self.allocator.free(normalized);
        var length: usize = 0;
        var index: usize = 0;
        while (index < source.len) : (index += 1) {
            const byte = source[index];
            normalized[length] = if (byte == '\r') '\n' else byte;
            length += 1;
            if (byte == '\r' and index + 1 < source.len and source[index + 1] == '\n') index += 1;
        }
        const lo = @min(self.selection[0], self.selection[1]);
        const hi = @max(self.selection[0], self.selection[1]);
        if (self.text().len - (hi - lo) + length > max_text_bytes) return error.TextTooLarge;
        self.pending_paste = try self.allocator.realloc(normalized, length);
        self.focus();
    }
    pub fn view(self: *Editor, c: *ui.Context, lines: u16) !Result {
        const active = self.buffer.want_focus or (self.buffer.last_id != 0 and
            (c.focus == self.buffer.last_id or (c.input.pressed and c.hot == self.buffer.last_id)));
        const incoming = c.input;
        defer {
            c.input.key = incoming.key;
            c.input.chars = incoming.chars;
            c.input.ops = incoming.ops;
            c.input.shift = incoming.shift;
        }
        if (active) {
            var step: i8 = 0;
            if (c.undo_op != .none) {
                step = if (c.undo_op == .redo) 1 else -1;
                c.undo_op = .none;
            } else if (c.shortcut(.{ .key = 'z', .cmd = true, .shift = true }) or c.shortcut(.{ .key = 'y', .cmd = true })) {
                step = 1;
            } else if (c.shortcut(.{ .key = 'z', .cmd = true })) {
                step = -1;
            }
            if (step != 0) {
                if (!self.composing) {
                    if (step < 0) _ = try self.undo() else _ = try self.redo();
                }
                c.input.key = null;
                c.input.chars = "";
                c.input.ops = &.{};
            }
        }
        const old_selection = self.selection;
        const old_composing = self.composing;
        const before_state = if (c.edits.getPtr(self.buffer.last_id)) |state| .{ state.caret, state.anchor, state.marked } else .{ self.selection[1], self.selection[0], @as(?[2]usize, null) };
        const has_input = active and (c.input.ops.len > 0 or c.input.chars.len > 0 or c.input.key != null or self.pending_paste != null);
        const backup = if (self.composing and has_input) try self.allocator.dupe(u8, self.text()) else null;
        defer if (backup) |owned| self.allocator.free(owned);
        const before = backup orelse if (self.composing) self.text() else self.history.current().text;
        if (!self.composing) self.history.setSelection(self.selection);
        var input_error: ?anyerror = null;
        if (active) self.prepareInput(c) catch |err| {
            input_error = err;
            c.input.key = null;
            c.input.chars = "";
            c.input.ops = &.{};
            if (self.pending_paste) |pending| {
                self.allocator.free(pending);
                self.pending_paste = null;
            }
        };
        if (c.edits.getPtr(self.buffer.last_id)) |state| state.undo = .{};
        const result = ui.textField(c, &self.buffer, .{
            .multiline = true,
            .max_lines = @max(1, lines),
            .width = .fill,
            .placeholder = "在这里写下正文",
            .size = 15,
        });
        const state = c.edits.getPtr(self.buffer.last_id) orelse return error.OutOfMemory;
        state.undo = .{};
        self.selection = .{ state.anchor, state.caret };
        const composing = state.marked != null;
        if (input_error) |err| return err;
        validate(self.text()) catch |err| {
            self.rollback(c, before, before_state, old_selection, old_composing);
            return err;
        };
        var changed = false;
        if (!composing) changed = self.history.record(self.text(), self.selection) catch |err| {
            self.rollback(c, before, before_state, old_selection, old_composing);
            return err;
        };
        self.composing = composing;
        if (active) if (self.pending_paste) |pending| {
            self.allocator.free(pending);
            self.pending_paste = null;
        };
        changed = (changed or self.pending_change) and !composing;
        if (!composing) self.pending_change = false;
        return .{ .changed = changed, .focused = result.focused, .composing = composing };
    }
    fn rollback(self: *Editor, c: *ui.Context, before: []const u8, state_before: anytype, selection: [2]usize, composing: bool) void {
        self.buffer.buf.items.len = before.len;
        std.mem.copyForwards(u8, self.buffer.buf.items, before);
        self.selection = selection;
        self.composing = composing;
        if (c.edits.getPtr(self.buffer.last_id)) |state| {
            state.caret = state_before[0];
            state.anchor = state_before[1];
            state.marked = state_before[2];
        }
        c.changed = true;
    }
    fn prepareInput(self: *Editor, c: *ui.Context) !void {
        var extra: usize = c.input.chars.len;
        try validate(c.input.chars);
        var prediction = Prediction{ .length = self.text().len, .selection = self.selection, .known = !c.input.pressed };
        if (c.edits.getPtr(self.buffer.last_id)) |state| prediction.marked = state.marked;
        const ops = try c.alloc().alloc(ui.TextOp, c.input.ops.len + @as(usize, if (self.pending_paste != null) 1 else 0));
        var explicit_newline = false;
        for (c.input.ops, 0..) |op, index| {
            ops[index] = op;
            switch (op) {
                .insert => |value| {
                    try validate(value);
                    extra = try std.math.add(usize, extra, value.len);
                    try prediction.insert(value.len, false);
                },
                .set_marked => |marked| {
                    try validate(marked.text);
                    const end = try std.math.add(usize, marked.sel_start, marked.sel_len);
                    if (!boundary(marked.text, marked.sel_start) or !boundary(marked.text, end)) return error.InvalidTextSelection;
                    extra = try std.math.add(usize, extra, marked.text.len);
                    try prediction.insert(marked.text.len, true);
                    if (prediction.marked) |range| prediction.selection = .{ range[0] + marked.sel_start, range[0] + end };
                },
                .unmark => prediction.marked = null,
                .select => |selection| {
                    prediction.selection = .{ @min(selection.anchor, prediction.length), @min(selection.caret, prediction.length) };
                    prediction.marked = null;
                },
                .command => |command| if (command == .insert_newline or command == .insert_line_break) {
                    ops[index] = .{ .command = .insert_line_break };
                    explicit_newline = true;
                    extra = try std.math.add(usize, extra, 1);
                    try prediction.insert(1, false);
                } else if (command == .select_all) {
                    prediction.selection = .{ 0, prediction.length };
                } else if (command != .copy) {
                    prediction.known = false;
                },
            }
        }
        if (self.pending_paste) |pending| {
            ops[ops.len - 1] = .{ .insert = pending };
            extra = try std.math.add(usize, extra, pending.len);
            try prediction.insert(pending.len, false);
        }
        if (c.input.chars.len > 0) try prediction.insert(c.input.chars.len, false);
        if (c.input.key == .enter) {
            if (explicit_newline) c.input.key = null else {
                c.input.shift = true;
                extra = try std.math.add(usize, extra, 1);
                try prediction.insert(1, false);
            }
        } else if (c.input.key == .backspace or c.input.key == .delete) prediction.known = false;
        if (prediction.known and prediction.length > max_text_bytes) return error.TextTooLarge;
        try self.buffer.buf.ensureTotalCapacity(std.heap.c_allocator, try std.math.add(usize, self.text().len, extra));
        c.input.ops = ops;
    }
};

const Prediction = struct {
    length: usize,
    selection: [2]usize,
    marked: ?[2]usize = null,
    known: bool,
    fn insert(self: *Prediction, length: usize, marked: bool) !void {
        if (!self.known) return;
        const range = if (self.marked) |value| value else self.selection;
        self.length = try std.math.add(usize, self.length - (range[1] - range[0]), length);
        if (marked) self.marked = .{ range[0], range[0] + length };
        self.selection = .{ range[0] + length, range[0] + length };
    }
};

fn boundary(text: []const u8, at: usize) bool {
    return at <= text.len and (at == text.len or (text[at] & 0xc0) != 0x80);
}
fn validate(text: []const u8) !void {
    if (text.len > max_text_bytes) return error.TextTooLarge;
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidText;
}
