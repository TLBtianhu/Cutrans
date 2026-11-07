//! bytecode.zig — CUI 视图声明装载器(启动时一次性执行)
//!
//! CUI version 2:
//!   24B 文件头:magic/version=2/header_size/view_count/record_size/strings_offset/strings_size
//!   N×12B 视图索引:id/label/icon 三个字符串 offset
//!   40B 定长节点记录,每个视图依次是 side 与 content 两棵先序树
//!   UTF-8 NUL 字符串区,按内容去重
//!
//! 节点记录:op/flags/action/kind/a,b,c:f32/s0..s3/action_arg/child_count。
//! action 只有 0=无命令、1=命令名;没有页面枚举或 goto 特例。
//! 字节码只含声明和名字,不含函数指针或裸地址。

const std = @import("std");
const n = @import("node.zig");
const theme = @import("theme.zig").theme;

const header_size = 24;
const view_entry_size = 12;
const record_size = 40;
const no_string = 0xffffffff;

pub const View = struct {
    id: [:0]const u8,
    label: [:0]const u8,
    icon: [:0]const u8,
    side: n.Node,
    content: n.Node,
};
pub const InputBinder = *const fn (name: [:0]const u8) ?[:0]u8;
pub const DecodeResult = struct { views: []View, node_count: u32 };

pub fn buttonKind(raw: u8) NodeError!n.ButtonKind {
    return switch (raw) {
        0 => .primary,
        1 => .secondary,
        2 => .launch,
        3 => .ghost,
        4 => .destructive,
        else => error.InvalidButtonKind,
    };
}

const NodeError = error{
    OutOfMemory,
    BadStringOffset,
    UnterminatedString,
    TruncatedRecord,
    InvalidAction,
    UnexpectedChildren,
    InvalidButtonKind,
    UnboundInputBuffer,
    InvalidChildCount,
    UnknownOpcode,
};

const Record = struct {
    op: u8,
    flags: u8,
    action: u8,
    kind: u8,
    a: f32,
    b: f32,
    c: f32,
    s0: u32,
    s1: u32,
    s2: u32,
    s3: u32,
    action_arg: u32,
    child_count: u32,
};

fn u16At(data: []const u8, off: usize) u16 {
    return @as(u16, data[off]) | (@as(u16, data[off + 1]) << 8);
}
fn u32At(data: []const u8, off: usize) u32 {
    return @as(u32, data[off]) |
        (@as(u32, data[off + 1]) << 8) |
        (@as(u32, data[off + 2]) << 16) |
        (@as(u32, data[off + 3]) << 24);
}
fn f32At(data: []const u8, off: usize) f32 {
    return @bitCast(u32At(data, off));
}

const Decoder = struct {
    allocator: std.mem.Allocator,
    bind_input: InputBinder,
    data: []const u8,
    pos: usize,
    strings_begin: usize,
    strings_end: usize,
    node_count: u32 = 0,

    fn string(self: *const Decoder, offset: u32) ![:0]const u8 {
        if (offset == no_string) return "";
        const relative_end = self.strings_end - self.strings_begin;
        const off: usize = @intCast(offset);
        if (off >= relative_end) return error.BadStringOffset;
        const start = self.strings_begin + off;
        const bytes = self.data[start..self.strings_end];
        const len = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.UnterminatedString;
        return bytes[0..len :0];
    }

    fn record(self: *Decoder) !Record {
        if (self.pos + record_size > self.strings_begin) return error.TruncatedRecord;
        const p = self.pos;
        self.pos += record_size;
        self.node_count += 1;
        return .{
            .op = self.data[p],
            .flags = self.data[p + 1],
            .action = self.data[p + 2],
            .kind = self.data[p + 3],
            .a = f32At(self.data, p + 4),
            .b = f32At(self.data, p + 8),
            .c = f32At(self.data, p + 12),
            .s0 = u32At(self.data, p + 16),
            .s1 = u32At(self.data, p + 20),
            .s2 = u32At(self.data, p + 24),
            .s3 = u32At(self.data, p + 28),
            .action_arg = u32At(self.data, p + 32),
            .child_count = u32At(self.data, p + 36),
        };
    }

    fn action(self: *Decoder, tag: u8, arg: u32) !n.Action {
        return switch (tag) {
            0 => null,
            1 => try self.string(arg),
            else => error.InvalidAction,
        };
    }

    fn children(self: *Decoder, count: u32) NodeError![]n.Node {
        const child_count: usize = @intCast(count);
        const remaining_records = (self.strings_begin - self.pos) / record_size;
        if (child_count > remaining_records) return error.InvalidChildCount;
        const result = try self.allocator.alloc(n.Node, child_count);
        for (result) |*child| child.* = try self.node();
        return result;
    }

    fn node(self: *Decoder) NodeError!n.Node {
        const rec = try self.record();
        if (rec.op < 5 or rec.op > 7) {
            if (rec.child_count != 0) return error.UnexpectedChildren;
        }
        return switch (rec.op) {
            1 => .{ .text = .{
                .s = try self.string(rec.s0),
                .color = if (rec.flags & 1 != 0) theme.dim else theme.text,
                .halign = if (rec.flags & 2 != 0) .center else .start,
                .size = rec.a,
            } },
            2 => .{ .button = .{
                .id = try self.string(rec.s0),
                .label = try self.string(rec.s1),
                .kind = try buttonKind(rec.kind),
                .h = rec.a,
                .sub = try self.string(rec.s2),
                .action = try self.action(rec.action, rec.action_arg),
            } },
            3 => .{ .list_item = .{
                .id = try self.string(rec.s0),
                .icon = try self.string(rec.s1),
                .title = try self.string(rec.s2),
                .info = try self.string(rec.s3),
                .selected = rec.flags & 4 != 0,
                .action = try self.action(rec.action, rec.action_arg),
            } },
            4 => .{ .input = .{
                .id = try self.string(rec.s0),
                .hint = try self.string(rec.s1),
                .buf = self.bind_input(try self.string(rec.s2)) orelse return error.UnboundInputBuffer,
            } },
            5 => .{ .card = .{
                .id = try self.string(rec.s0),
                .pad = rec.a,
                .w = if (rec.flags & 8 != 0) rec.b else null,
                .h = if (rec.flags & 16 != 0) rec.c else null,
                .children = try self.children(rec.child_count),
            } },
            6 => .{ .vstack = .{
                .gap = rec.a,
                .margin = rec.b,
                .children = try self.children(rec.child_count),
            } },
            7 => .{ .hstack = .{
                .gap = rec.a,
                .margin = rec.b,
                .children = try self.children(rec.child_count),
            } },
            8 => .{ .space = rec.a },
            else => error.UnknownOpcode,
        };
    }
};

pub fn decode(allocator: std.mem.Allocator, data: []const u8, bind_input: InputBinder) !DecodeResult {
    if (data.len < header_size) return error.TruncatedHeader;
    if (!std.mem.eql(u8, data[0..4], "CUI1")) return error.BadMagic;
    if (u16At(data, 4) != 2) return error.UnsupportedVersion;
    if (u16At(data, 6) != header_size) return error.BadHeaderSize;
    if (u32At(data, 12) != record_size) return error.BadRecordSize;

    const view_count: usize = @intCast(u32At(data, 8));
    if (view_count > 1024) return error.TooManyViews;
    const table_bytes = view_count * view_entry_size;
    const strings_begin: usize = @intCast(u32At(data, 16));
    const strings_size: usize = @intCast(u32At(data, 20));
    if (strings_begin < header_size + table_bytes or strings_begin > data.len) return error.BadStringSection;
    if (strings_size > data.len - strings_begin) return error.BadStringSection;
    const strings_end = strings_begin + strings_size;
    if (strings_end != data.len) return error.TrailingData;

    var decoder = Decoder{
        .allocator = allocator,
        .bind_input = bind_input,
        .data = data,
        .pos = header_size + table_bytes,
        .strings_begin = strings_begin,
        .strings_end = strings_end,
    };
    const views = try allocator.alloc(View, view_count);
    for (views, 0..) |*view, i| {
        const entry = header_size + i * view_entry_size;
        view.id = try decoder.string(u32At(data, entry));
        view.label = try decoder.string(u32At(data, entry + 4));
        view.icon = try decoder.string(u32At(data, entry + 8));
        view.side = try decoder.node();
        view.content = try decoder.node();
    }
    if (decoder.pos != strings_begin) return error.TrailingNodeData;
    return .{ .views = views, .node_count = decoder.node_count };
}

test "button kind mapping preserves old kinds and accepts new variants" {
    try std.testing.expectEqual(n.ButtonKind.primary, try buttonKind(0));
    try std.testing.expectEqual(n.ButtonKind.secondary, try buttonKind(1));
    try std.testing.expectEqual(n.ButtonKind.launch, try buttonKind(2));
    try std.testing.expectEqual(n.ButtonKind.ghost, try buttonKind(3));
    try std.testing.expectEqual(n.ButtonKind.destructive, try buttonKind(4));
    try std.testing.expectError(error.InvalidButtonKind, buttonKind(5));
}
