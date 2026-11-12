//! history.zig — 0 层增量编辑日志与 undo/redo
//!
//! 字段编辑记录前后值,add 记录结构差分;整文档替换单独记录。
//! 不保存像素帧,不引入全量快照栈或二分梯层。

const std = @import("std");
const documents = @import("vne").documents;

pub const Edit = union(enum) {
    gain_set: struct { id: u64, before: f32, after: f32 },
    over_opacity_set: struct { id: u64, before: f32, after: f32 },
    add_invert: struct { id: u64, input: u64, previous_output: ?u64 },
    add_over: struct { id: u64, bottom: u64, top: u64, opacity: f32, previous_output: ?u64 },
    add_resize: struct { id: u64, input: u64, width: u32, height: u32, previous_output: ?u64, old_width: u32, old_height: u32 },
    replace_document: struct { before: documents.Document, after: documents.Document },
};

pub const History = struct {
    pub const capacity = 256;
    entries: [capacity]Edit = undefined,
    count: usize = 0,
    cursor: usize = 0,

    pub fn init(self: *History) void {
        self.* = .{};
    }

    pub fn reset(self: *History) void {
        self.init();
    }

    pub fn record(self: *History, edit: Edit) !void {
        if (self.cursor < self.count) self.count = self.cursor;
        if (self.count == self.entries.len) return error.HistoryFull;
        self.entries[self.count] = edit;
        self.count += 1;
        self.cursor = self.count;
    }

    pub fn undo(self: *History, doc: *documents.Document) bool {
        if (self.cursor == 0) return false;
        const edit = self.entries[self.cursor - 1];
        if (!applyUndo(edit, doc)) return false;
        self.cursor -= 1;
        return true;
    }

    pub fn redo(self: *History, doc: *documents.Document) bool {
        if (self.cursor == self.count) return false;
        const edit = self.entries[self.cursor];
        if (!applyRedo(edit, doc)) return false;
        self.cursor += 1;
        return true;
    }
};

fn removeLast(doc: *documents.Document, id: u64) bool {
    if (doc.count == 0 or doc.nodes[doc.count - 1].id != id) return false;
    doc.count -= 1;
    doc.output_id = if (doc.count == 0) null else doc.nodes[doc.count - 1].id;
    doc.dirty = true;
    return true;
}

fn appendNode(doc: *documents.Document, node: documents.Node) bool {
    if (doc.count == doc.nodes.len) return false;
    doc.nodes[doc.count] = node;
    doc.count += 1;
    doc.output_id = node.id;
    doc.observeNodeId(node.id);
    doc.dirty = true;
    return true;
}

/// Apply to an unpublished document candidate; the caller owns cursor commit.
pub fn applyUndo(edit: Edit, doc: *documents.Document) bool {
    switch (edit) {
        .gain_set => |value| doc.setGain(value.id, value.before) catch return false,
        .over_opacity_set => |value| doc.setOverOpacity(value.id, value.before) catch return false,
        .add_invert => |value| {
            if (!removeLast(doc, value.id)) return false;
            doc.output_id = value.previous_output;
        },
        .add_over => |value| {
            if (!removeLast(doc, value.id)) return false;
            doc.output_id = value.previous_output;
        },
        .add_resize => |value| {
            if (!removeLast(doc, value.id)) return false;
            doc.output_id = value.previous_output;
            doc.width = value.old_width;
            doc.height = value.old_height;
        },
        .replace_document => |value| doc.replacePreservingIdentity(&value.before),
    }
    return true;
}

pub fn applyRedo(edit: Edit, doc: *documents.Document) bool {
    switch (edit) {
        .gain_set => |value| doc.setGain(value.id, value.after) catch return false,
        .over_opacity_set => |value| doc.setOverOpacity(value.id, value.after) catch return false,
        .add_invert => |value| {
            if (!appendNode(doc, .{ .id = value.id, .op = .invert, .birth = .{ .transform = value.input } })) return false;
        },
        .add_over => |value| {
            if (!appendNode(doc, .{
                .id = value.id,
                .op = .over,
                .birth = .{ .aggregate = .{
                    .items = .{ .{ .input = value.bottom }, .{ .input = value.top, .opacity = value.opacity } },
                    .count = 2,
                } },
            })) return false;
        },
        .add_resize => |value| {
            if (!appendNode(doc, .{ .id = value.id, .op = .resize, .birth = .{ .transform = value.input }, .out_w = value.width, .out_h = value.height })) return false;
            doc.width = value.width;
            doc.height = value.height;
        },
        .replace_document => |value| doc.replacePreservingIdentity(&value.after),
    }
    return true;
}

test "field edits and add operations support undo and redo" {
    var history: History = .{};
    var doc = documents.Document.initDefault();
    try history.record(.{ .gain_set = .{ .id = 1, .before = 0.8, .after = 0.25 } });
    try doc.setGain(1, 0.25);
    try std.testing.expect(history.undo(&doc));
    try std.testing.expectEqual(@as(f32, 0.8), doc.nodes[1].value);
    try std.testing.expect(history.redo(&doc));
    try std.testing.expectEqual(@as(f32, 0.25), doc.nodes[1].value);

    const previous_output = doc.outputId();
    const id = try doc.addInvert(1);
    try history.record(.{ .add_invert = .{ .id = id, .input = 1, .previous_output = previous_output } });
    try std.testing.expect(history.undo(&doc));
    try std.testing.expectEqual(@as(usize, 2), doc.count);
    try std.testing.expectEqual(previous_output, doc.outputId());
    try std.testing.expect(history.redo(&doc));
    try std.testing.expectEqual(id, doc.outputId());
}

test "resize undo restores dimensions and a new edit truncates redo" {
    var history: History = .{};
    var doc = documents.Document.initDefault();
    const previous_output = doc.outputId();
    const old_width = doc.width;
    const old_height = doc.height;
    const id = try doc.addResize(1, 182, 138);
    try history.record(.{ .add_resize = .{
        .id = id,
        .input = 1,
        .width = 182,
        .height = 138,
        .previous_output = previous_output,
        .old_width = old_width,
        .old_height = old_height,
    } });
    try std.testing.expect(history.undo(&doc));
    try std.testing.expectEqual(old_width, doc.width);
    try std.testing.expectEqual(old_height, doc.height);
    try std.testing.expect(history.redo(&doc));
    try std.testing.expectEqual(@as(u32, 182), doc.width);
    try std.testing.expectEqual(@as(u32, 138), doc.height);
    try std.testing.expect(history.undo(&doc));
    _ = try doc.addInvert(1);
    try history.record(.{ .add_invert = .{ .id = 3, .input = 1, .previous_output = previous_output } });
    try std.testing.expect(!history.redo(&doc));
}

test "document replacement restores the complete previous declaration" {
    var history: History = .{};
    var doc = documents.Document.initDefault();
    const before = doc;
    try doc.setImage("assets/examples/pngtest.png", 91, 69);
    try history.record(.{ .replace_document = .{ .before = before, .after = doc } });
    try std.testing.expect(history.undo(&doc));
    try std.testing.expectEqual(before.fingerprint(), doc.fingerprint());
    try std.testing.expect(history.redo(&doc));
    try std.testing.expectEqual(@as(u32, 91), doc.width);
    try std.testing.expectEqual(@as(u32, 69), doc.height);
}

test "undo redo and new branches never recycle an issued node identity" {
    const value = try std.testing.allocator.create(History);
    defer std.testing.allocator.destroy(value);
    value.init();
    var doc = documents.Document.initDefault();
    const output = doc.outputId();
    const original = try doc.addInvert(output.?);
    try value.record(.{ .add_invert = .{ .id = original, .input = output.?, .previous_output = output } });
    try std.testing.expect(value.undo(&doc));
    try std.testing.expectEqual(original, doc.nodeIdHighWater());
    try std.testing.expect(value.redo(&doc));
    try std.testing.expectEqual(original, doc.outputId().?);
    try std.testing.expect(value.undo(&doc));
    const branch = try doc.addResize(output.?, 320, 180);
    try std.testing.expect(branch > original);
    try value.record(.{ .add_resize = .{ .id = branch, .input = output.?, .width = 320, .height = 180, .previous_output = output, .old_width = 1920, .old_height = 1080 } });
    try std.testing.expect(!value.redo(&doc));
    try std.testing.expect(value.undo(&doc));
    try std.testing.expectEqual(branch, doc.nodeIdHighWater());
}

test "document replacement undo and redo preserve identity high water across both declarations" {
    const value = try std.testing.allocator.create(History);
    defer std.testing.allocator.destroy(value);
    value.init();
    var doc = documents.Document.initDefault();
    _ = try doc.addInvert(1);
    const before = doc;
    try doc.setImage("source.png", 1, 1);
    const image_id = doc.outputId().?;
    try value.record(.{ .replace_document = .{ .before = before, .after = doc } });
    try std.testing.expect(value.undo(&doc));
    try std.testing.expectEqual(before.fingerprint(), doc.fingerprint());
    try std.testing.expectEqual(image_id, doc.nodeIdHighWater());
    try std.testing.expect(value.redo(&doc));
    try std.testing.expectEqual(image_id, doc.outputId().?);
    try std.testing.expect(value.undo(&doc));
    try std.testing.expect((try doc.addInvert(doc.outputId().?)) > image_id);
}
