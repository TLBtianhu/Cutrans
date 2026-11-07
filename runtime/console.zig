//! console.zig — 一个会话的 CLI 控制台状态

const surfaces = @import("surfaces.zig");

pub const HistoryEntry = struct { text: [96]u8, len: usize };

pub const State = struct {
    history: [8]HistoryEntry = undefined,
    history_count: usize = 0,
    focus_next: bool = false,
    dragging: bool = false,
    drag_pos: [2]f32 = undefined,
    drag_rect: surfaces.Rect = .{},
    input_buf: [256:0]u8 = @import("std").mem.zeroes([256:0]u8),

    pub fn reset(self: *State) void {
        self.history_count = 0;
        self.focus_next = false;
        self.dragging = false;
        self.input_buf[0] = 0;
    }
};
