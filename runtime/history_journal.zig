//! history_journal.zig — 版本化 History 快照与原子恢复
//!
//! 文件持有当前声明、游标和差分编辑;replace_document 的声明用 .cut 规范文本
//! 编码。先完整解析并验证指纹,再一次替换 History,坏文件不会清空有效撤销栈。

const std = @import("std");
const documents = @import("documents.zig");
const history = @import("history.zig");
const storage = @import("storage.zig");

pub const journal_path = "documents/history.txt";
const codec = std.base64.standard_no_pad;

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendOptional(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: ?u64) !void {
    if (value) |id| try appendFmt(out, allocator, "{d}", .{id}) else try out.appendSlice(allocator, "-");
}

fn appendDocument(out: *std.ArrayList(u8), allocator: std.mem.Allocator, doc: *const documents.Document) !void {
    const text = try documents.emitAlloc(doc, allocator);
    defer allocator.free(text);
    const encoded = try allocator.alloc(u8, codec.Encoder.calcSize(text.len));
    defer allocator.free(encoded);
    try out.appendSlice(allocator, codec.Encoder.encode(encoded, text));
}

/// Borrow existing history and optionally append one unpublished edit. This
/// lets a candidate be persisted without copying the large fixed History.
pub const View = struct {
    entries: []const history.Edit,
    appended: ?*const history.Edit = null,
    cursor: usize,

    pub fn count(self: View) usize {
        return self.entries.len + @intFromBool(self.appended != null);
    }
};

pub fn save(value: *const history.History, doc: *const documents.Document, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    return saveView(.{ .entries = value.entries[0..value.count], .cursor = value.cursor }, doc, allocator, io, dir);
}

pub fn saveView(value: View, doc: *const documents.Document, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    if (value.cursor > value.count() or value.count() > history.History.capacity) return error.InvalidHistoryJournal;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "cutrans_history=1\n");
    try appendFmt(&out, allocator, "fingerprint={d}\ncursor={d}\ncount={d}\ndocument=", .{ doc.fingerprint(), value.cursor, value.count() });
    try appendDocument(&out, allocator, doc);
    try out.appendSlice(allocator, "\n");
    for (0..value.count()) |index| {
        const edit = if (index < value.entries.len) value.entries[index] else value.appended.?.*;
        switch (edit) {
            .gain_set => |item| try appendFmt(&out, allocator, "edit=gain_set,{d},{d},{d}\n", .{ item.id, item.before, item.after }),
            .over_opacity_set => |item| try appendFmt(&out, allocator, "edit=over_opacity_set,{d},{d},{d}\n", .{ item.id, item.before, item.after }),
            .add_invert => |item| {
                try appendFmt(&out, allocator, "edit=add_invert,{d},{d},", .{ item.id, item.input });
                try appendOptional(&out, allocator, item.previous_output);
                try out.appendSlice(allocator, "\n");
            },
            .add_over => |item| {
                try appendFmt(&out, allocator, "edit=add_over,{d},{d},{d},{d},", .{ item.id, item.bottom, item.top, item.opacity });
                try appendOptional(&out, allocator, item.previous_output);
                try out.appendSlice(allocator, "\n");
            },
            .add_resize => |item| {
                try appendFmt(&out, allocator, "edit=add_resize,{d},{d},{d},{d},", .{ item.id, item.input, item.width, item.height });
                try appendOptional(&out, allocator, item.previous_output);
                try appendFmt(&out, allocator, ",{d},{d}\n", .{ item.old_width, item.old_height });
            },
            .replace_document => |item| {
                try out.appendSlice(allocator, "edit=replace_document,");
                try appendDocument(&out, allocator, &item.before);
                try out.appendSlice(allocator, ",");
                try appendDocument(&out, allocator, &item.after);
                try out.appendSlice(allocator, "\n");
            },
        }
    }
    try storage.writeAtomic(dir, io, journal_path, out.items);
}

const Fields = struct {
    items: [8][]const u8,
    count: usize,

    fn parse(line: []const u8, expected: usize) !Fields {
        var result: Fields = .{ .items = undefined, .count = 0 };
        var parts = std.mem.splitScalar(u8, line, ',');
        while (parts.next()) |part| {
            if (result.count == result.items.len) return error.InvalidHistoryJournal;
            result.items[result.count] = part;
            result.count += 1;
        }
        if (result.count != expected) return error.InvalidHistoryJournal;
        return result;
    }

    fn at(self: Fields, index: usize) []const u8 {
        return self.items[index];
    }
};

fn unsigned(comptime T: type, text: []const u8) !T {
    return std.fmt.parseInt(T, text, 10) catch return error.InvalidHistoryJournal;
}

fn float(text: []const u8) !f32 {
    const value = std.fmt.parseFloat(f32, text) catch return error.InvalidHistoryJournal;
    if (!std.math.isFinite(value)) return error.InvalidHistoryJournal;
    return value;
}

fn optionalId(text: []const u8) !?u64 {
    if (std.mem.eql(u8, text, "-")) return null;
    return try unsigned(u64, text);
}

fn parseDocument(allocator: std.mem.Allocator, text: []const u8) !documents.Document {
    const decoded_len = codec.Decoder.calcSizeForSlice(text) catch return error.InvalidHistoryJournal;
    if (decoded_len > 64 * 1024) return error.InvalidHistoryJournal;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    codec.Decoder.decode(decoded, text) catch return error.InvalidHistoryJournal;
    return documents.parse(decoded) catch return error.InvalidHistoryJournal;
}

fn parseEdit(allocator: std.mem.Allocator, line: []const u8) !history.Edit {
    const body = line["edit=".len..];
    if (std.mem.startsWith(u8, body, "replace_document,")) {
        const fields = try Fields.parse(body, 3);
        return .{ .replace_document = .{
            .before = try parseDocument(allocator, fields.at(1)),
            .after = try parseDocument(allocator, fields.at(2)),
        } };
    }
    if (std.mem.startsWith(u8, body, "add_resize,")) {
        const fields = try Fields.parse(body, 8);
        return .{ .add_resize = .{
            .id = try unsigned(u64, fields.at(1)),
            .input = try unsigned(u64, fields.at(2)),
            .width = try unsigned(u32, fields.at(3)),
            .height = try unsigned(u32, fields.at(4)),
            .previous_output = try optionalId(fields.at(5)),
            .old_width = try unsigned(u32, fields.at(6)),
            .old_height = try unsigned(u32, fields.at(7)),
        } };
    }
    if (std.mem.startsWith(u8, body, "add_over,")) {
        const fields = try Fields.parse(body, 6);
        return .{ .add_over = .{
            .id = try unsigned(u64, fields.at(1)),
            .bottom = try unsigned(u64, fields.at(2)),
            .top = try unsigned(u64, fields.at(3)),
            .opacity = try float(fields.at(4)),
            .previous_output = try optionalId(fields.at(5)),
        } };
    }
    if (std.mem.startsWith(u8, body, "add_invert,")) {
        const fields = try Fields.parse(body, 4);
        return .{ .add_invert = .{
            .id = try unsigned(u64, fields.at(1)),
            .input = try unsigned(u64, fields.at(2)),
            .previous_output = try optionalId(fields.at(3)),
        } };
    }
    if (std.mem.startsWith(u8, body, "gain_set,") or std.mem.startsWith(u8, body, "over_opacity_set,")) {
        const fields = try Fields.parse(body, 4);
        if (std.mem.startsWith(u8, body, "gain_set,")) return .{ .gain_set = .{
            .id = try unsigned(u64, fields.at(1)),
            .before = try float(fields.at(2)),
            .after = try float(fields.at(3)),
        } };
        return .{ .over_opacity_set = .{
            .id = try unsigned(u64, fields.at(1)),
            .before = try float(fields.at(2)),
            .after = try float(fields.at(3)),
        } };
    }
    return error.InvalidHistoryJournal;
}

// Older journals did not persist administrative identity metadata. Both sides
// of the cursor still contain issued identities, including undone branches.
fn observeEditIds(doc: *documents.Document, edit: history.Edit) void {
    switch (edit) {
        .gain_set => |item| doc.observeNodeId(item.id),
        .over_opacity_set => |item| doc.observeNodeId(item.id),
        .add_invert => |item| {
            doc.observeNodeId(item.id);
            doc.observeNodeId(item.input);
            if (item.previous_output) |id| doc.observeNodeId(id);
        },
        .add_over => |item| {
            doc.observeNodeId(item.id);
            doc.observeNodeId(item.bottom);
            doc.observeNodeId(item.top);
            if (item.previous_output) |id| doc.observeNodeId(id);
        },
        .add_resize => |item| {
            doc.observeNodeId(item.id);
            doc.observeNodeId(item.input);
            if (item.previous_output) |id| doc.observeNodeId(id);
        },
        .replace_document => |item| {
            doc.observeNodeId(item.before.nodeIdHighWater());
            doc.observeNodeId(item.after.nodeIdHighWater());
        },
    }
}

pub fn load(value: *history.History, doc: *documents.Document, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !bool {
    const text = dir.readFileAlloc(io, journal_path, allocator, .limited(4 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    defer allocator.free(text);
    const restored = try allocator.create(history.History);
    defer allocator.destroy(restored);
    restored.init();
    var restored_doc: ?documents.Document = null;
    var expected_fingerprint: ?u64 = null;
    var declared_count: ?usize = null;
    var saw_header = false;
    var saw_cursor = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "cutrans_history=1")) {
            if (saw_header) return error.InvalidHistoryJournal;
            saw_header = true;
        } else if (std.mem.startsWith(u8, line, "fingerprint=")) {
            if (expected_fingerprint != null) return error.InvalidHistoryJournal;
            expected_fingerprint = try unsigned(u64, line["fingerprint=".len..]);
        } else if (std.mem.startsWith(u8, line, "cursor=")) {
            if (saw_cursor) return error.InvalidHistoryJournal;
            restored.cursor = try unsigned(usize, line["cursor=".len..]);
            saw_cursor = true;
        } else if (std.mem.startsWith(u8, line, "count=")) {
            if (declared_count != null) return error.InvalidHistoryJournal;
            declared_count = try unsigned(usize, line["count=".len..]);
            if (declared_count.? > restored.entries.len) return error.InvalidHistoryJournal;
        } else if (std.mem.startsWith(u8, line, "document=")) {
            if (restored_doc != null) return error.InvalidHistoryJournal;
            restored_doc = try parseDocument(allocator, line["document=".len..]);
        } else if (std.mem.startsWith(u8, line, "edit=")) {
            if (restored.count == restored.entries.len) return error.InvalidHistoryJournal;
            restored.entries[restored.count] = try parseEdit(allocator, line);
            restored.count += 1;
        } else return error.InvalidHistoryJournal;
    }
    const fingerprint = expected_fingerprint orelse return error.InvalidHistoryJournal;
    var current_doc = restored_doc orelse return error.InvalidHistoryJournal;
    if (!saw_header or !saw_cursor or declared_count == null or restored.count != declared_count.?) return error.InvalidHistoryJournal;
    if (restored.cursor > restored.count or current_doc.fingerprint() != fingerprint) return error.InvalidHistoryJournal;
    for (restored.entries[0..restored.count]) |edit| observeEditIds(&current_doc, edit);
    value.* = restored.*;
    doc.* = current_doc;
    doc.dirty = false;
    return true;
}

test "history journal restores cursor edits and full replacements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var value: history.History = .{};
    var doc = documents.Document.initDefault();
    const before = doc;
    try value.record(.{ .gain_set = .{ .id = 1, .before = 0.8, .after = 0.25 } });
    try doc.setGain(1, 0.25);
    const previous_output = doc.outputId();
    const id = try doc.addInvert(1);
    try value.record(.{ .add_invert = .{ .id = id, .input = 1, .previous_output = previous_output } });
    const replaced = doc;
    try doc.setImage("assets/examples/pngtest.png", 91, 69);
    try value.record(.{ .replace_document = .{ .before = replaced, .after = doc } });
    try std.testing.expect(value.undo(&doc));
    try save(&value, &doc, std.testing.allocator, std.testing.io, tmp.dir);

    var restored: history.History = .{};
    var restored_doc = documents.Document.initDefault();
    try std.testing.expect(try load(&restored, &restored_doc, std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(replaced.fingerprint(), restored_doc.fingerprint());
    try std.testing.expectEqual(value.count, restored.count);
    try std.testing.expectEqual(value.cursor, restored.cursor);
    try std.testing.expect(restored.redo(&restored_doc));
    try std.testing.expectEqual(@as(u32, 91), restored_doc.width);
    try std.testing.expect(restored.undo(&restored_doc));
    try std.testing.expect(restored.undo(&restored_doc));
    try std.testing.expectEqual(previous_output, restored_doc.outputId());
    try std.testing.expectEqual(before.count, restored_doc.count);
}

test "corrupt or mismatched history preserves the last valid state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var value: history.History = .{};
    try value.record(.{ .gain_set = .{ .id = 1, .before = 0.8, .after = 0.25 } });
    var doc = documents.Document.initDefault();
    try doc.setGain(1, 0.25);
    try save(&value, &doc, std.testing.allocator, std.testing.io, tmp.dir);

    const valid = try tmp.dir.readFileAlloc(std.testing.io, journal_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(valid);
    const tampered = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(tampered);
    const fingerprint_at = (std.mem.indexOf(u8, tampered, "fingerprint=") orelse return error.TestUnexpectedResult) + "fingerprint=".len;
    tampered[fingerprint_at] = if (tampered[fingerprint_at] == '0') '1' else '0';
    try storage.writeAtomic(tmp.dir, std.testing.io, journal_path, tampered);
    try std.testing.expectError(error.InvalidHistoryJournal, load(&value, &doc, std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(@as(usize, 1), value.count);
    try std.testing.expectEqual(@as(f32, 0.25), doc.nodes[1].value);

    const cut = std.mem.indexOf(u8, valid, "edit=gain_set") orelse return error.TestUnexpectedResult;
    try storage.writeAtomic(tmp.dir, std.testing.io, journal_path, valid[0 .. cut + 5]);
    try std.testing.expectError(error.InvalidHistoryJournal, load(&value, &doc, std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(@as(usize, 1), value.count);
    try std.testing.expectEqual(@as(f32, 0.25), doc.nodes[1].value);
}

test "old history journals derive high water from undone edits before a new branch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const value = try std.testing.allocator.create(history.History);
    defer std.testing.allocator.destroy(value);
    value.init();
    var doc = documents.Document.initDefault();
    const previous_output = doc.outputId();
    const id = try doc.addInvert(1);
    try value.record(.{ .add_invert = .{ .id = id, .input = 1, .previous_output = previous_output } });
    try std.testing.expect(value.undo(&doc));
    // Deliberately model the old writer, which retained redo but not the ID
    // administrative metadata. Restoration must observe the undone record.
    doc.node_id_high_water = 1;
    try save(value, &doc, std.testing.allocator, std.testing.io, tmp.dir);
    const restored = try std.testing.allocator.create(history.History);
    defer std.testing.allocator.destroy(restored);
    restored.init();
    var restored_doc = documents.Document.initDefault();
    try std.testing.expect(try load(restored, &restored_doc, std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(id, restored_doc.nodeIdHighWater());
    try std.testing.expect((try restored_doc.addInvert(1)) > id);
}

test "history retains IDs from replaced declarations and saves sparse standalone identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const value = try std.testing.allocator.create(history.History);
    defer std.testing.allocator.destroy(value);
    value.init();
    var doc = documents.Document.initDefault();
    const before = doc;
    try doc.setImage("source.png", 1, 1);
    const image_id = doc.outputId().?;
    try value.record(.{ .replace_document = .{ .before = before, .after = doc } });
    try std.testing.expect(value.undo(&doc));
    try save(value, &doc, std.testing.allocator, std.testing.io, tmp.dir);
    const restored = try std.testing.allocator.create(history.History);
    defer std.testing.allocator.destroy(restored);
    restored.init();
    var restored_doc = documents.Document.initDefault();
    try std.testing.expect(try load(restored, &restored_doc, std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(before.fingerprint(), restored_doc.fingerprint());
    try std.testing.expectEqual(image_id, restored_doc.nodeIdHighWater());
    try documents.save(&restored_doc, std.testing.io, std.testing.allocator, tmp.dir, "standalone.cut");
    var standalone = documents.Document.initDefault();
    try documents.open(&standalone, std.testing.io, std.testing.allocator, tmp.dir, "standalone.cut");
    try std.testing.expect((try standalone.addInvert(1)) > image_id);
}
