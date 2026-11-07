//! stream.zig — 静态文档流:把一份声明映射为有限帧序列
//!
//! 流本体无线程、无 L1/L2、无自主预产;Playback 可同步预取。get 负责按需物化,
//! has 只查询当前工作帧是否已物化且与文档指纹一致,不把“声明上存在”误当成“字节已就绪”。

const std = @import("std");
const documents = @import("documents.zig");
const render = @import("render.zig");

pub const Stream = struct {
    document: *const documents.Document,
    preview: render.Preview,
    frames: i64,
    provider: ?render.SourceProvider = null,

    pub fn init(document: *const documents.Document, frames: i64) Stream {
        return .{ .document = document, .preview = .{}, .frames = frames };
    }

    pub fn initWithProvider(document: *const documents.Document, frames: i64, provider: render.SourceProvider) Stream {
        return .{ .document = document, .preview = .{}, .frames = frames, .provider = provider };
    }

    pub fn deinit(self: *Stream, allocator: std.mem.Allocator) void {
        self.preview.deinit(allocator);
        self.frames = 0;
    }

    pub fn has(self: *const Stream, t: i64) bool {
        if (t < 0 or t >= self.frames) return false;
        if (self.preview.frame == null) return false;
        return self.preview.fingerprint == self.document.fingerprint();
    }

    pub fn get(self: *Stream, t: i64, allocator: std.mem.Allocator, io: ?std.Io, dir: ?std.Io.Dir) !*const render.Frame {
        if (t < 0 or t >= self.frames) return error.EndOfStream;
        if (self.provider) |provider| return self.preview.currentWithProvider(self.document, allocator, provider);
        if (io != null and dir != null) {
            return self.preview.currentWithDir(self.document, allocator, io.?, dir.?);
        }
        return self.preview.current(self.document, allocator);
    }
};

test "static document stream materializes on demand and checks frame bounds" {
    var doc = documents.Document.initDefault();
    doc.width = 1;
    doc.height = 1;
    var stream = Stream.init(&doc, 2);
    defer stream.deinit(std.testing.allocator);
    try std.testing.expect(!stream.has(0));
    const frame = try stream.get(0, std.testing.allocator, null, null);
    try std.testing.expectEqual(@as(u32, 26), frame.pixels[0]);
    try std.testing.expect(stream.has(0));
    try std.testing.expect(stream.has(1));
    try std.testing.expect(!stream.has(-1));
    try std.testing.expect(!stream.has(2));
    try std.testing.expectError(error.EndOfStream, stream.get(-1, std.testing.allocator, null, null));
    try std.testing.expectError(error.EndOfStream, stream.get(2, std.testing.allocator, null, null));
}
