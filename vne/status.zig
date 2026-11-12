//! status.zig — 可实例化的系统最近状态文本

pub const Status = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Status, text: []const u8) void {
        self.len = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..self.len], text[0..self.len]);
    }

    pub fn get(self: *const Status) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn clear(self: *Status) void {
        self.len = 0;
    }
};
