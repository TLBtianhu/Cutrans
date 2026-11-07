//! documents.zig — 最小 .cut 文档、校验、规范化输出与文件往返
//!
//! 当前只支持 resolution/fps/testsrc/gain/invert/over/image/resize。节点是固定数组和值类型,
//! over 先限定两个输入,不宣称完整 Cutrans 语言、效果器或渲染器已经实现。

const std = @import("std");
const high_water_prefix = "// cutrans.node-id-high-water-v1=";

pub const Op = enum { testsrc, gain, invert, over, image, resize };
pub const AggIn = struct {
    input: u64,
    x: f32 = 0,
    y: f32 = 0,
    opacity: f32 = 1,
    t: i64 = 0,
};
pub const Aggregate = struct {
    items: [2]AggIn,
    count: u8,
};
pub const Birth = union(enum) {
    inspire,
    transform: u64,
    aggregate: Aggregate,
};
pub const Node = struct {
    id: u64,
    op: Op,
    birth: Birth = .inspire,
    value: f32 = 0,
    out_w: u32 = 0,
    out_h: u32 = 0,
    asset_path: [160]u8 = std.mem.zeroes([160]u8),
    asset_len: u16 = 0,
    asset_hash: [32]u8 = std.mem.zeroes([32]u8),
    asset_hash_present: bool = false,
    legacy_asset: bool = false,

    pub fn asset(self: *const Node) []const u8 {
        return self.asset_path[0..self.asset_len];
    }

    pub fn unaryInput(self: *const Node) ?u64 {
        return switch (self.birth) {
            .transform => |input| input,
            else => null,
        };
    }

    pub fn aggInput(self: *const Node, index: usize) ?u64 {
        return switch (self.birth) {
            .aggregate => |aggregate| if (index < aggregate.count) aggregate.items[index].input else null,
            else => null,
        };
    }

    pub fn aggCount(self: *const Node) u8 {
        return switch (self.birth) {
            .aggregate => |aggregate| aggregate.count,
            else => 0,
        };
    }

    pub fn topOpacity(self: *const Node) f32 {
        return switch (self.birth) {
            .aggregate => |aggregate| aggregate.items[1].opacity,
            else => 1,
        };
    }
};

fn writeSource(node: *Node, path: []const u8, content_hash: ?[32]u8) !void {
    if (std.mem.startsWith(u8, path, "session://") or std.mem.startsWith(u8, path, "external://") or std.mem.startsWith(u8, path, "library://")) {
        const uri = try @import("vne").uri.parse(path);
        if ((uri.root != .session and uri.root != .external and uri.root != .library) or content_hash == null or path.len > node.asset_path.len) return error.InvalidResourcePath;
        @memcpy(node.asset_path[0..path.len], path);
        node.asset_len = @intCast(path.len);
    } else {
        const normalized = try @import("vne").uri.writePack(&node.asset_path, path);
        node.asset_len = @intCast(normalized.len);
    }
    node.asset_hash_present = content_hash != null;
    if (content_hash) |value| node.asset_hash = value;
}

pub const Document = struct {
    width: u32,
    height: u32,
    fps: u32,
    nodes: [8]Node,
    count: usize,
    output_id: ?u64 = null,
    dirty: bool,
    legacy: bool = false,
    legacy_paths: bool = false,
    // Administrative identity state, deliberately excluded from content hashes.
    // It survives undo even when the highest issued node is no longer visible.
    node_id_high_water: u64 = 1,

    pub fn initDefault() Document {
        return .{
            .width = 1920,
            .height = 1080,
            .fps = 30,
            .nodes = .{
                .{ .id = 0, .op = .testsrc },
                .{ .id = 1, .op = .gain, .birth = .{ .transform = 0 }, .value = 0.8 },
                undefined,
                undefined,
                undefined,
                undefined,
                undefined,
                undefined,
            },
            .count = 2,
            .output_id = 1,
            .dirty = false,
        };
    }

    fn fingerprintMix(hash: *u64, value: anytype) void {
        const T = @TypeOf(value);
        const U = switch (T) {
            bool => u8,
            usize => u64,
            else => T,
        };
        const normalized: U = switch (T) {
            bool => @intFromBool(value),
            usize => @intCast(value),
            else => value,
        };
        var bytes: [@sizeOf(U)]u8 = undefined;
        std.mem.writeInt(U, &bytes, normalized, .little);
        for (bytes) |byte| {
            hash.* ^= byte;
            hash.* *%= 1099511628211;
        }
    }

    pub fn fingerprint(self: *const Document) u64 {
        var hash: u64 = 14695981039346656037;
        fingerprintMix(&hash, self.width);
        fingerprintMix(&hash, self.height);
        fingerprintMix(&hash, self.fps);
        fingerprintMix(&hash, self.count);
        fingerprintMix(&hash, self.output_id != null);
        if (self.output_id) |output| fingerprintMix(&hash, output);
        for (self.nodes[0..self.count]) |node| {
            fingerprintMix(&hash, node.id);
            fingerprintMix(&hash, @as(u8, @intCast(@backingInt(node.op))));
            switch (node.birth) {
                .inspire => {},
                .transform => |input| fingerprintMix(&hash, input),
                .aggregate => |aggregate| {
                    fingerprintMix(&hash, aggregate.count);
                    for (aggregate.items[0..aggregate.count]) |input| {
                        fingerprintMix(&hash, input.input);
                        const x_bits: u32 = @bitCast(input.x);
                        const y_bits: u32 = @bitCast(input.y);
                        const opacity_bits: u32 = @bitCast(input.opacity);
                        fingerprintMix(&hash, x_bits);
                        fingerprintMix(&hash, y_bits);
                        fingerprintMix(&hash, opacity_bits);
                        fingerprintMix(&hash, input.t);
                    }
                },
            }
            fingerprintMix(&hash, node.out_w);
            fingerprintMix(&hash, node.out_h);
            for (node.asset()) |byte| fingerprintMix(&hash, byte);
            fingerprintMix(&hash, node.asset_hash_present);
            if (node.asset_hash_present) for (node.asset_hash) |byte| fingerprintMix(&hash, byte);
            const value_bits: u32 = @bitCast(node.value);
            fingerprintMix(&hash, value_bits);
        }
        return hash;
    }

    pub fn setGain(self: *Document, id: u64, value: f32) !void {
        if (!std.math.isFinite(value) or value < 0 or value > 2) return error.InvalidGain;
        for (self.nodes[0..self.count]) |*node| {
            if (node.id == id and node.op == .gain) {
                node.value = value;
                self.dirty = true;
                return;
            }
        }
        return error.InvalidGainTarget;
    }

    pub fn firstGainId(self: *const Document) ?u64 {
        for (self.nodes[0..self.count]) |node| {
            if (node.op == .gain) return node.id;
        }
        return null;
    }

    pub fn outputId(self: *const Document) ?u64 {
        return self.output_id;
    }

    pub fn nodeIdHighWater(self: *const Document) u64 {
        var highest = self.node_id_high_water;
        for (self.nodes[0..self.count]) |node| highest = @max(highest, node.id);
        return highest;
    }

    pub fn observeNodeId(self: *Document, id: u64) void {
        self.node_id_high_water = @max(self.nodeIdHighWater(), id);
    }

    pub fn replacePreservingIdentity(self: *Document, other: *const Document) void {
        const highest = @max(self.nodeIdHighWater(), other.nodeIdHighWater());
        self.* = other.*;
        self.node_id_high_water = highest;
    }

    pub fn setImage(self: *Document, path: []const u8, width: u32, height: u32) !void {
        return self.setImageSource(path, null, width, height);
    }

    pub fn setImageSource(self: *Document, path: []const u8, content_hash: ?[32]u8, width: u32, height: u32) !void {
        if (path.len == 0) return error.InvalidResourcePath;
        if (width == 0 or height == 0) return error.InvalidSize;
        const id = try self.nextId();
        var node = Node{ .id = id, .op = .image };
        try writeSource(&node, path, content_hash);
        self.nodes[0] = node;
        self.width = width;
        self.height = height;
        self.count = 1;
        self.output_id = id;
        self.observeNodeId(id);
        self.dirty = true;
        self.legacy = false;
        self.legacy_paths = false;
    }

    pub fn hasV3Source(self: *const Document) bool {
        for (self.nodes[0..self.count]) |node| {
            if (node.op == .image and (node.asset_hash_present or std.mem.startsWith(u8, node.asset(), "session://"))) return true;
        }
        return false;
    }

    fn hasNodeId(self: *const Document, id: u64) bool {
        for (self.nodes[0..self.count]) |node| {
            if (node.id == id) return true;
        }
        return false;
    }

    fn nextId(self: *const Document) !u64 {
        if (self.count == 0) return error.EmptyDocument;
        const highest = self.nodeIdHighWater();
        if (highest == std.math.maxInt(u64)) return error.IdOverflow;
        return highest + 1;
    }

    pub fn addInvert(self: *Document, input: u64) !u64 {
        if (!self.hasNodeId(input)) return error.InvalidReference;
        if (self.count == self.nodes.len) return error.TooManyNodes;
        const id = try self.nextId();
        self.nodes[self.count] = .{ .id = id, .op = .invert, .birth = .{ .transform = input } };
        self.count += 1;
        self.output_id = id;
        self.observeNodeId(id);
        self.dirty = true;
        return id;
    }

    pub fn addOver(self: *Document, bottom: u64, top: u64, opacity: f32) !u64 {
        if (!self.hasNodeId(bottom) or !self.hasNodeId(top)) return error.InvalidReference;
        if (self.count == self.nodes.len) return error.TooManyNodes;
        if (!std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.InvalidOpacity;
        const id = try self.nextId();
        self.nodes[self.count] = .{
            .id = id,
            .op = .over,
            .birth = .{ .aggregate = .{
                .items = .{ .{ .input = bottom }, .{ .input = top, .opacity = opacity } },
                .count = 2,
            } },
        };
        self.count += 1;
        self.output_id = id;
        self.observeNodeId(id);
        self.dirty = true;
        return id;
    }

    pub fn addResize(self: *Document, input: u64, width: u32, height: u32) !u64 {
        if (!self.hasNodeId(input)) return error.InvalidReference;
        if (self.count == self.nodes.len) return error.TooManyNodes;
        if (width == 0 or height == 0) return error.InvalidSize;
        const id = try self.nextId();
        self.nodes[self.count] = .{ .id = id, .op = .resize, .birth = .{ .transform = input }, .out_w = width, .out_h = height };
        self.count += 1;
        self.output_id = id;
        self.observeNodeId(id);
        self.width = width;
        self.height = height;
        self.dirty = true;
        return id;
    }

    pub fn setOverOpacity(self: *Document, id: u64, opacity: f32) !void {
        if (!std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.InvalidOpacity;
        for (self.nodes[0..self.count]) |*node| {
            if (node.id == id and node.op == .over) {
                node.birth.aggregate.items[1].opacity = opacity;
                self.dirty = true;
                return;
            }
        }
        return error.InvalidOpacityTarget;
    }

    pub fn setGainText(self: *Document, text: []const u8) !void {
        var parts = std.mem.tokenizeAny(u8, text, " \t");
        const first = parts.next() orelse return error.MissingGainArgument;
        const second = parts.next();
        var id: u64 = undefined;
        if (second) |_| {
            id = try parseCompId(first);
        } else {
            id = self.firstGainId() orelse return error.InvalidGainTarget;
        }
        const value_text = second orelse first;
        if (parts.next() != null) return error.InvalidGain;
        const value = try std.fmt.parseFloat(f32, value_text);
        try self.setGain(id, value);
    }
};

pub fn parseCompId(text: []const u8) !u64 {
    if (text.len < 2 or text[0] != 'c') return error.InvalidNodeId;
    for (text[1..]) |ch| {
        if (!std.ascii.isDigit(ch)) return error.InvalidNodeId;
    }
    return std.fmt.parseInt(u64, text[1..], 10);
}

fn hasComp(doc: *const Document, id: u64) bool {
    for (doc.nodes[0..doc.count]) |node| {
        if (node.id == id) return true;
    }
    return false;
}

fn requireReference(doc: *const Document, id: u64, input: u64) !void {
    if (input >= id or !hasComp(doc, input)) return error.InvalidReference;
}

fn parseUnary(id: u64, op: Op, body: []const u8) !Node {
    var input: ?u64 = null;
    var value: ?f32 = null;
    var parts = std.mem.splitScalar(u8, body, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (std.mem.startsWith(u8, part, "in:")) {
            input = try parseCompId(std.mem.trim(u8, part[3..], " \t"));
        } else if (op == .gain and std.mem.startsWith(u8, part, "value:")) {
            value = try std.fmt.parseFloat(f32, std.mem.trim(u8, part[6..], " \t"));
        } else return error.InvalidNode;
    }
    const input_id = input orelse return error.InvalidNode;
    if (op == .invert) return .{ .id = id, .op = op, .birth = .{ .transform = input_id } };
    const gain = value orelse return error.InvalidGain;
    if (!std.math.isFinite(gain) or gain < 0 or gain > 2) return error.InvalidGain;
    return .{ .id = id, .op = op, .birth = .{ .transform = input_id }, .value = gain };
}

fn parseResize(id: u64, body: []const u8) !Node {
    var input: ?u64 = null;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var parts = std.mem.splitScalar(u8, body, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (std.mem.startsWith(u8, part, "in:")) {
            input = try parseCompId(std.mem.trim(u8, part[3..], " \t"));
        } else if (std.mem.startsWith(u8, part, "w:")) {
            width = try std.fmt.parseInt(u32, std.mem.trim(u8, part[2..], " \t"), 10);
        } else if (std.mem.startsWith(u8, part, "h:")) {
            height = try std.fmt.parseInt(u32, std.mem.trim(u8, part[2..], " \t"), 10);
        } else return error.InvalidNode;
    }
    if (width == null or height == null or width.? == 0 or height.? == 0) return error.InvalidSize;
    return .{ .id = id, .op = .resize, .birth = .{ .transform = input orelse return error.InvalidNode }, .out_w = width.?, .out_h = height.? };
}

fn parseOver(id: u64, body: []const u8) !Node {
    var rest = std.mem.trim(u8, body, " \t");
    var inputs: [2]AggIn = undefined;
    var count: usize = 0;
    while (rest.len > 0) {
        if (count == 2 or !std.mem.startsWith(u8, rest, ".{")) return error.InvalidNode;
        const close = std.mem.indexOfScalar(u8, rest, '}') orelse return error.InvalidNode;
        const entry = std.mem.trim(u8, rest[2..close], " \t");
        var input: ?u64 = null;
        var x: f32 = 0;
        var y: f32 = 0;
        var t: i64 = 0;
        var entry_opacity: ?f32 = null;
        var parts = std.mem.splitScalar(u8, entry, ',');
        while (parts.next()) |part_raw| {
            const part = std.mem.trim(u8, part_raw, " \t");
            if (std.mem.startsWith(u8, part, "in:")) {
                if (input != null) return error.InvalidNode;
                input = try parseCompId(std.mem.trim(u8, part[3..], " \t"));
            } else if (std.mem.startsWith(u8, part, "x:")) {
                if (x != 0) return error.InvalidNode;
                x = try std.fmt.parseFloat(f32, std.mem.trim(u8, part[2..], " \t"));
            } else if (std.mem.startsWith(u8, part, "y:")) {
                if (y != 0) return error.InvalidNode;
                y = try std.fmt.parseFloat(f32, std.mem.trim(u8, part[2..], " \t"));
            } else if (std.mem.startsWith(u8, part, "t:")) {
                if (t != 0) return error.InvalidNode;
                t = try std.fmt.parseInt(i64, std.mem.trim(u8, part[2..], " \t"), 10);
            } else if (std.mem.startsWith(u8, part, "opacity:")) {
                if (entry_opacity != null) return error.InvalidNode;
                entry_opacity = try std.fmt.parseFloat(f32, std.mem.trim(u8, part[8..], " \t"));
            } else return error.InvalidNode;
        }
        const opacity = entry_opacity orelse 1;
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(opacity)) return error.InvalidNode;
        inputs[count] = .{ .input = input orelse return error.InvalidNode, .x = x, .y = y, .t = t, .opacity = opacity };
        count += 1;
        rest = std.mem.trim(u8, rest[close + 1 ..], " \t");
        if (rest.len > 0 and rest[0] == ',') rest = std.mem.trim(u8, rest[1..], " \t");
    }
    if (count != 2 or inputs[1].opacity < 0 or inputs[1].opacity > 1) return error.InvalidNode;
    return .{ .id = id, .op = .over, .birth = .{ .aggregate = .{ .items = inputs, .count = 2 } } };
}

fn parseImage(id: u64, body: []const u8) !Node {
    if (!std.mem.startsWith(u8, body, "path:")) return error.InvalidNode;
    const hash_start = std.mem.indexOf(u8, body, ",sha256:");
    const value = std.mem.trim(u8, body[5 .. hash_start orelse body.len], " \t");
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidNode;
    const path = value[1 .. value.len - 1];
    if (path.len == 0) return error.InvalidResourcePath;
    var node = Node{
        .id = id,
        .op = .image,
        .legacy_asset = !std.mem.startsWith(u8, path, "pack://") and !std.mem.startsWith(u8, path, "session://") and !std.mem.startsWith(u8, path, "external://") and !std.mem.startsWith(u8, path, "library://"),
    };
    var content_hash: ?[32]u8 = null;
    if (hash_start) |start| {
        const hash_text = std.mem.trim(u8, body[start + ",sha256:".len ..], " \t");
        if (hash_text.len != 66 or hash_text[0] != '"' or hash_text[65] != '"') return error.InvalidSourceHash;
        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, hash_text[1..65]) catch return error.InvalidSourceHash;
        content_hash = digest;
    }
    try writeSource(&node, path, content_hash);
    return node;
}

fn parseNode(doc: *Document, line: []const u8) !void {
    const open_brace = std.mem.indexOfScalar(u8, line, '{') orelse return error.InvalidNode;
    if (line.len < 3 or line[line.len - 1] != '}') return error.InvalidNode;
    const eq = std.mem.indexOfScalar(u8, line[0..open_brace], '=') orelse return error.InvalidNode;
    const id = try parseCompId(std.mem.trim(u8, line[0..eq], " \t"));
    const op_text = std.mem.trim(u8, line[eq + 1 .. open_brace], " \t");
    const op = std.meta.stringToEnum(Op, op_text) orelse return error.UnsupportedOperation;
    if (doc.count > 0 and id <= doc.nodes[doc.count - 1].id) return error.NonMonotonicNodeId;
    if (doc.count == doc.nodes.len) return error.TooManyNodes;
    const body = std.mem.trim(u8, line[open_brace + 1 .. line.len - 1], " \t");
    const node = switch (op) {
        .testsrc => if (body.len == 0) Node{ .id = id, .op = .testsrc } else return error.InvalidNode,
        .gain, .invert => try parseUnary(id, op, body),
        .over => try parseOver(id, body),
        .image => try parseImage(id, body),
        .resize => try parseResize(id, body),
    };
    switch (node.birth) {
        .inspire => {},
        .transform => |input| try requireReference(doc, id, input),
        .aggregate => |aggregate| {
            for (aggregate.items[0..aggregate.count]) |input| try requireReference(doc, id, input.input);
        },
    }
    doc.nodes[doc.count] = node;
    if (node.legacy_asset) doc.legacy_paths = true;
    doc.count += 1;
    doc.output_id = id;
    doc.observeNodeId(id);
}

pub fn parse(text: []const u8) !Document {
    var doc = Document.initDefault();
    doc.count = 0;
    doc.node_id_high_water = 0;
    var declared_high_water: ?u64 = null;
    var saw_version = false;
    var version: u32 = 0;
    var output_override: ?u64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, high_water_prefix)) {
            if (declared_high_water != null) return error.InvalidNodeIdentityMetadata;
            const value = line[high_water_prefix.len..];
            if (value.len == 0) return error.InvalidNodeIdentityMetadata;
            for (value) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidNodeIdentityMetadata;
            declared_high_water = std.fmt.parseInt(u64, value, 10) catch return error.InvalidNodeIdentityMetadata;
            continue;
        }
        if (std.mem.startsWith(u8, line, "// cutrans.node-id-high-water-")) return error.UnsupportedNodeIdentityMetadata;
        if (line.len == 0 or line[0] == '#' or std.mem.startsWith(u8, line, "//") or std.mem.eql(u8, line, "nodes:")) continue;
        if (std.mem.startsWith(u8, line, "version=")) {
            if (saw_version) return error.DuplicateVersion;
            version = try std.fmt.parseInt(u32, line[8..], 10);
            if (version < 1 or version > 3) return error.UnsupportedVersion;
            saw_version = true;
        } else if (std.mem.startsWith(u8, line, "resolution=")) {
            const value = line[11..];
            const x = std.mem.indexOfScalar(u8, value, 'x') orelse return error.InvalidResolution;
            doc.width = try std.fmt.parseInt(u32, value[0..x], 10);
            doc.height = try std.fmt.parseInt(u32, value[x + 1 ..], 10);
            if (doc.width == 0 or doc.height == 0) return error.InvalidResolution;
        } else if (std.mem.startsWith(u8, line, "fps=")) {
            doc.fps = try std.fmt.parseInt(u32, line[4..], 10);
            if (doc.fps == 0) return error.InvalidFps;
        } else if (std.mem.startsWith(u8, line, "output=")) {
            if (output_override != null) return error.DuplicateOutput;
            output_override = try parseCompId(std.mem.trim(u8, line["output=".len..], " \t"));
        } else if (line[0] == 'c') {
            try parseNode(&doc, line);
        } else return error.InvalidLine;
    }
    if (doc.count == 0) return error.EmptyDocument;
    if (declared_high_water) |highest| {
        if (highest < doc.nodeIdHighWater()) return error.InvalidNodeIdentityMetadata;
        doc.node_id_high_water = highest;
    }
    if (output_override) |output| {
        if (!hasComp(&doc, output)) return error.InvalidReference;
        doc.output_id = output;
    }
    if (saw_version and version == 2 and doc.legacy_paths) return error.InvalidResourcePath;
    if ((!saw_version or version < 3) and doc.hasV3Source()) return error.InvalidResourcePath;
    doc.legacy = !saw_version or version == 1;
    return doc;
}

fn appendFmt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try list.appendSlice(allocator, text);
}

fn appendAggregateInput(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: AggIn, top: bool) !void {
    try appendFmt(out, allocator, ".{{in:c{d}", .{input.input});
    if (input.x != 0) try appendFmt(out, allocator, ",x:{d}", .{input.x});
    if (input.y != 0) try appendFmt(out, allocator, ",y:{d}", .{input.y});
    if (top or input.opacity != 1) try appendFmt(out, allocator, ",opacity:{d}", .{input.opacity});
    if (input.t != 0) try appendFmt(out, allocator, ",t:{d}", .{input.t});
    try out.appendSlice(allocator, "}");
}

pub fn emitAlloc(doc: *const Document, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "version=3\n");
    try appendFmt(&out, allocator, "resolution={d}x{d}\n", .{ doc.width, doc.height });
    try appendFmt(&out, allocator, "fps={d}\n", .{doc.fps});
    try out.appendSlice(allocator, "nodes:\n");
    for (doc.nodes[0..doc.count]) |node| {
        switch (node.op) {
            .testsrc => try appendFmt(&out, allocator, "c{d}=testsrc{{}}\n", .{node.id}),
            .gain => try appendFmt(&out, allocator, "c{d}=gain{{ in:c{d},value:{d} }}\n", .{ node.id, node.unaryInput().?, node.value }),
            .invert => try appendFmt(&out, allocator, "c{d}=invert{{ in:c{d} }}\n", .{ node.id, node.unaryInput().? }),
            .over => {
                try appendFmt(&out, allocator, "c{d}=over{{ ", .{node.id});
                try appendAggregateInput(&out, allocator, node.birth.aggregate.items[0], false);
                try out.appendSlice(allocator, ", ");
                try appendAggregateInput(&out, allocator, node.birth.aggregate.items[1], true);
                try out.appendSlice(allocator, " }\n");
            },
            .image => {
                try appendFmt(&out, allocator, "c{d}=image{{ path:\"{s}\"", .{ node.id, node.asset() });
                if (node.asset_hash_present) {
                    const digest = std.fmt.bytesToHex(node.asset_hash, .lower);
                    try appendFmt(&out, allocator, ",sha256:\"{s}\"", .{&digest});
                }
                try out.appendSlice(allocator, " }\n");
            },
            .resize => try appendFmt(&out, allocator, "c{d}=resize{{ in:c{d},w:{d},h:{d} }}\n", .{ node.id, node.unaryInput().?, node.out_w, node.out_h }),
        }
    }
    const output = doc.outputId() orelse return error.EmptyDocument;
    if (!hasComp(doc, output)) return error.InvalidReference;
    try appendFmt(&out, allocator, "output=c{d}\n", .{output});
    var visible_high_water: u64 = 0;
    for (doc.nodes[0..doc.count]) |node| visible_high_water = @max(visible_high_water, node.id);
    const high_water = doc.nodeIdHighWater();
    if (high_water > visible_high_water) try appendFmt(&out, allocator, "{s}{d}\n", .{ high_water_prefix, high_water });
    return out.toOwnedSlice(allocator);
}

fn validPath(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path) or std.mem.indexOf(u8, path, "..") != null) return error.InvalidResourcePath;
}

fn loadFromDir(doc: *Document, io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) !void {
    try validPath(path);
    const text = try dir.readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(text);
    doc.* = try parse(text);
    doc.dirty = false;
}

pub fn open(doc: *Document, io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) !void {
    loadFromDir(doc, io, allocator, dir, path) catch |err| {
        if (err == error.FileNotFound) {
            doc.* = Document.initDefault();
            return;
        }
        return err;
    };
}

pub fn write(doc: *Document, io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) !void {
    try loadFromDir(doc, io, allocator, dir, path);
}

pub fn save(doc: *Document, io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) !void {
    try validPath(path);
    const text = try emitAlloc(doc, allocator);
    defer allocator.free(text);
    try dir.writeFile(io, .{ .sub_path = path, .data = text });
    doc.dirty = false;
    doc.legacy = false;
    doc.legacy_paths = false;
}

fn validExternalPath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) try validPath(path);
}

pub fn openExternal(doc: *Document, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    try validExternalPath(path);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(text);
    doc.* = try parse(text);
    doc.dirty = false;
}

pub fn saveExternal(doc: *Document, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    try validExternalPath(path);
    const text = try emitAlloc(doc, allocator);
    defer allocator.free(text);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
    doc.dirty = false;
    doc.legacy = false;
    doc.legacy_paths = false;
}

test "explicit external documents support absolute paths without resource fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "external document.cut" });
    defer std.testing.allocator.free(path);
    var doc = Document.initDefault();
    try doc.setGain(1, 0.375);
    try saveExternal(&doc, std.testing.io, std.testing.allocator, path);
    var restored = Document.initDefault();
    try openExternal(&restored, std.testing.io, std.testing.allocator, path);
    try std.testing.expectEqual(@as(f32, 0.375), restored.nodes[1].value);
    try std.testing.expectEqual(doc.fingerprint(), restored.fingerprint());
    try std.testing.expect(!restored.dirty);
    try std.testing.expectError(error.InvalidResourcePath, saveExternal(&doc, std.testing.io, std.testing.allocator, "../outside.cut"));
    const missing = try std.fs.path.join(std.testing.allocator, &.{ root, "missing.cut" });
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.FileNotFound, openExternal(&restored, std.testing.io, std.testing.allocator, missing));
    try std.testing.expectEqual(doc.fingerprint(), restored.fingerprint());
}

test "document edit emit parse round trip is canonical" {
    var doc = Document.initDefault();
    try doc.setGain(1, 0.5);
    const text = try emitAlloc(&doc, std.testing.allocator);
    defer std.testing.allocator.free(text);
    var restored = try parse(text);
    try std.testing.expectEqual(@as(u32, 1920), restored.width);
    try std.testing.expectEqual(@as(u32, 1080), restored.height);
    try std.testing.expectEqual(@as(u32, 30), restored.fps);
    try std.testing.expectEqual(@as(usize, 2), restored.count);
    try std.testing.expectEqual(@as(f32, 0.5), restored.nodes[1].value);
    const canonical = try emitAlloc(&restored, std.testing.allocator);
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings(text, canonical);
}

test "document rejects bad references and unsupported operations" {
    try std.testing.expectError(error.InvalidReference, parse("resolution=1920x1080\nfps=30\nc1=gain{ in:c1,value:0.5 }\n"));
    try std.testing.expectError(error.UnsupportedOperation, parse("c0=blur{}\n"));
}

test "gain text commands and missing-file default are deterministic" {
    var doc = Document.initDefault();
    try doc.setGainText("0.4");
    try std.testing.expectEqual(@as(f32, 0.4), doc.nodes[1].value);
    try doc.setGainText("c1 0.6");
    try std.testing.expectEqual(@as(f32, 0.6), doc.nodes[1].value);
    try std.testing.expectError(error.InvalidGainTarget, doc.setGainText("c9 0.1"));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fallback = Document.initDefault();
    try open(&fallback, std.testing.io, std.testing.allocator, tmp.dir, "missing.cut");
    try std.testing.expectEqual(@as(usize, 2), fallback.count);
    try std.testing.expectEqual(@as(f32, 0.8), fallback.nodes[1].value);
}

test "document file write and reopen preserve edits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var doc = Document.initDefault();
    try doc.setGain(1, 0.25);
    try save(&doc, std.testing.io, std.testing.allocator, tmp.dir, "session.cut");
    var restored = Document.initDefault();
    try open(&restored, std.testing.io, std.testing.allocator, tmp.dir, "session.cut");
    try std.testing.expectEqual(@as(f32, 0.25), restored.nodes[1].value);
    try std.testing.expect(!restored.dirty);
}

test "invert and over have a canonical lossless round trip" {
    const source = "version=2\nresolution=1x1\nfps=30\nnodes:\nc0=testsrc{}\nc1=invert{ in:c0 }\nc2=over{ .{in:c0}, .{in:c1,opacity:0.25} }\noutput=c2\n";
    const expected = "version=3\nresolution=1x1\nfps=30\nnodes:\nc0=testsrc{}\nc1=invert{ in:c0 }\nc2=over{ .{in:c0}, .{in:c1,opacity:0.25} }\noutput=c2\n";
    var doc = try parse(source);
    try std.testing.expectEqual(@as(usize, 3), doc.count);
    try std.testing.expectEqual(Op.invert, doc.nodes[1].op);
    try std.testing.expectEqual(Op.over, doc.nodes[2].op);
    try std.testing.expectEqual(@as(f32, 0.25), doc.nodes[2].topOpacity());
    try std.testing.expect(!doc.legacy);
    const text = try emitAlloc(&doc, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
    try std.testing.expectError(error.InvalidReference, parse("c0=testsrc{}\nc1=over{ .{in:c0}, .{in:c9} }\n"));
}

test "legacy documents migrate to version three and unknown versions fail" {
    const legacy_source = "resolution=1x1\nfps=30\nc0=testsrc{}\n";
    var doc = try parse(legacy_source);
    try std.testing.expect(doc.legacy);
    const text = try emitAlloc(&doc, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "version=3\n"));
    var migrated = try parse(text);
    try std.testing.expect(!migrated.legacy);
    try std.testing.expectEqual(doc.fingerprint(), migrated.fingerprint());
    try std.testing.expectError(error.UnsupportedVersion, parse("version=4\nc0=testsrc{}\n"));
    try std.testing.expectError(error.DuplicateVersion, parse("version=2\nversion=2\nc0=testsrc{}\n"));
}

test "version two requires pack URIs and migrates legacy image paths" {
    try std.testing.expectError(error.InvalidResourcePath, parse("version=2\nc0=image{ path:\"assets/example.png\" }\n"));
    var migrated = try parse("version=1\nc0=image{ path:\"assets/example.png\" }\n");
    try std.testing.expectEqualStrings("pack://assets/example.png", migrated.nodes[0].asset());
    const text = try emitAlloc(&migrated, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "version=3\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "pack://assets/example.png") != null);
    var reparsed = try parse(text);
    try std.testing.expect(!reparsed.legacy_paths);
    try std.testing.expectEqual(migrated.fingerprint(), reparsed.fingerprint());
}

test "output selection and aggregate parameters affect document identity" {
    var doc = Document.initDefault();
    try std.testing.expectEqual(@as(u64, 1), doc.outputId().?);
    _ = try doc.addInvert(1);
    try std.testing.expectEqual(@as(u64, 2), doc.outputId().?);
    _ = try doc.addOver(0, 2, 0.25);
    try std.testing.expectEqual(@as(u64, 3), doc.outputId().?);
    try std.testing.expectEqual(@as(u8, 2), doc.nodes[3].aggCount());
    doc.output_id = 1;
    try std.testing.expectEqual(@as(u64, 1), doc.outputId().?);
    const before = doc.fingerprint();
    doc.nodes[3].birth.aggregate.items[1].x = 4;
    try std.testing.expect(before != doc.fingerprint());
    doc.output_id = 0;
    try std.testing.expect(before != doc.fingerprint());
}

test "command-built DAG has a stable fingerprint after save and reload" {
    var doc = Document.initDefault();
    _ = try doc.addInvert(1);
    _ = try doc.addOver(0, 2, 0.25);
    const text = try emitAlloc(&doc, std.testing.allocator);
    defer std.testing.allocator.free(text);
    var restored = try parse(text);
    try std.testing.expectEqual(doc.fingerprint(), restored.fingerprint());
}

test "fingerprint hashes asset contents instead of document addresses" {
    var first = Document.initDefault();
    var second = Document.initDefault();
    try std.testing.expectEqual(first.fingerprint(), second.fingerprint());
    try first.setImage("assets/examples/pngtest.png", 91, 69);
    try second.setImage("assets/examples/pngtest.png", 91, 69);
    try std.testing.expectEqual(first.fingerprint(), second.fingerprint());
    second.nodes[0].asset_path[0] = 'X';
    try std.testing.expect(first.fingerprint() != second.fingerprint());
}

test "fingerprint mixes integers in fixed width little endian form" {
    var actual: u64 = 0;
    Document.fingerprintMix(&actual, @as(u16, 0x1234));
    Document.fingerprintMix(&actual, @as(usize, 0x05060708));
    const bytes = [_]u8{ 0x34, 0x12, 0x08, 0x07, 0x06, 0x05, 0, 0, 0, 0 };
    var expected: u64 = 0;
    for (bytes) |byte| {
        expected ^= byte;
        expected *%= 1099511628211;
    }
    try std.testing.expectEqual(expected, actual);
}

test "explicit output and all aggregate fields survive canonical round trip" {
    var doc = Document.initDefault();
    doc.width = 1;
    doc.height = 1;
    _ = try doc.addOver(0, 1, 0.25);
    doc.nodes[2].birth.aggregate.items[0].x = -2.5;
    doc.nodes[2].birth.aggregate.items[0].y = 3.5;
    doc.nodes[2].birth.aggregate.items[0].opacity = 0.75;
    doc.nodes[2].birth.aggregate.items[0].t = -7;
    doc.output_id = 0;
    const expected = "version=3\nresolution=1x1\nfps=30\nnodes:\nc0=testsrc{}\nc1=gain{ in:c0,value:0.8 }\nc2=over{ .{in:c0,x:-2.5,y:3.5,opacity:0.75,t:-7}, .{in:c1,opacity:0.25} }\noutput=c0\n";
    const text = try emitAlloc(&doc, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
    var restored = try parse(text);
    try std.testing.expectEqual(@as(u64, 0), restored.outputId().?);
    try std.testing.expectEqual(doc.fingerprint(), restored.fingerprint());
    try std.testing.expectEqual(@as(f32, -2.5), restored.nodes[2].birth.aggregate.items[0].x);
    try std.testing.expectEqual(@as(f32, 3.5), restored.nodes[2].birth.aggregate.items[0].y);
    try std.testing.expectEqual(@as(f32, 0.75), restored.nodes[2].birth.aggregate.items[0].opacity);
    try std.testing.expectEqual(@as(i64, -7), restored.nodes[2].birth.aggregate.items[0].t);
}

test "output duplicates and missing output references are rejected" {
    try std.testing.expectError(error.DuplicateOutput, parse("c0=testsrc{}\noutput=c0\noutput=c0\n"));
    try std.testing.expectError(error.InvalidReference, parse("c0=testsrc{}\noutput=c9\n"));
}

test "v3 session sources preserve content identity through canonical round trips" {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("snapshot-content", &digest, .{});
    var doc = Document.initDefault();
    try doc.setImageSource("session://snapshots/one", digest, 91, 69);
    const text = try emitAlloc(&doc, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "version=3\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "path:\"session://snapshots/one\",sha256:\"") != null);
    var restored = try parse(text);
    try std.testing.expectEqual(digest, restored.nodes[0].asset_hash);
    try std.testing.expect(restored.nodes[0].asset_hash_present);
    try std.testing.expectEqual(doc.fingerprint(), restored.fingerprint());
    restored.nodes[0].asset_hash[0] ^= 1;
    try std.testing.expect(doc.fingerprint() != restored.fingerprint());
    const v2 = try std.mem.replaceOwned(u8, std.testing.allocator, text, "version=3", "version=2");
    defer std.testing.allocator.free(v2);
    try std.testing.expectError(error.InvalidResourcePath, parse(v2));
    try std.testing.expectError(error.InvalidResourcePath, parse("version=3\nc0=image{ path:\"session://snapshots/missing\" }\n"));
    try std.testing.expectError(error.InvalidResourcePath, parse("version=3\nc0=image{ path:\"external://1\" }\n"));
    try doc.setImageSource("external://7", digest, 91, 69);
    const external_text = try emitAlloc(&doc, std.testing.allocator);
    defer std.testing.allocator.free(external_text);
    var external = try parse(external_text);
    try std.testing.expectEqualStrings("external://7", external.nodes[0].asset());
    try std.testing.expectEqual(digest, external.nodes[0].asset_hash);
    try std.testing.expectEqual(doc.fingerprint(), external.fingerprint());
}

test "node identity high water survives undo-shaped gaps and independent save reopen" {
    var doc = Document.initDefault();
    const original = doc.fingerprint();
    const issued = try doc.addInvert(1);
    doc.count -= 1;
    doc.output_id = 1;
    try std.testing.expectEqual(original, doc.fingerprint());
    const text = try emitAlloc(&doc, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, high_water_prefix) != null);
    var parsed = try parse(text);
    try std.testing.expectEqual(issued, parsed.nodeIdHighWater());
    try std.testing.expectEqual(original, parsed.fingerprint());
    try std.testing.expectEqual(issued + 1, try parsed.addInvert(1));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try save(&doc, std.testing.io, std.testing.allocator, tmp.dir, "identity.cut");
    var reopened = Document.initDefault();
    try open(&reopened, std.testing.io, std.testing.allocator, tmp.dir, "identity.cut");
    try std.testing.expectEqual(issued + 1, try reopened.addInvert(1));
}

test "identity metadata is validated without changing ordinary v3 canonical text" {
    const normal = "version=3\nresolution=1920x1080\nfps=30\nnodes:\nc0=testsrc{}\nc1=gain{ in:c0,value:0.8 }\noutput=c1\n";
    const doc = try parse(normal);
    const text = try emitAlloc(&doc, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(normal, text);
    try std.testing.expectError(error.InvalidNodeIdentityMetadata, parse("c1=testsrc{}\n// cutrans.node-id-high-water-v1=0\n"));
    try std.testing.expectError(error.InvalidNodeIdentityMetadata, parse("c0=testsrc{}\n// cutrans.node-id-high-water-v1=1\n// cutrans.node-id-high-water-v1=2\n"));
    try std.testing.expectError(error.InvalidNodeIdentityMetadata, parse("c0=testsrc{}\n// cutrans.node-id-high-water-v1=-1\n"));
    try std.testing.expectError(error.UnsupportedNodeIdentityMetadata, parse("c0=testsrc{}\n// cutrans.node-id-high-water-v2=2\n"));
    var exhausted = try parse("c18446744073709551615=testsrc{}\n");
    try std.testing.expectError(error.IdOverflow, exhausted.addInvert(std.math.maxInt(u64)));
    var legacy = try parse("c7=testsrc{}\n");
    try std.testing.expectEqual(@as(u64, 8), try legacy.addInvert(7));
}

test "image replacement allocates a new identity and failed source validation preserves document" {
    var doc = Document.initDefault();
    const highest = try doc.addInvert(1);
    try doc.setImage("source.png", 2, 1);
    try std.testing.expectEqual(highest + 1, doc.outputId().?);
    const before = doc;
    try std.testing.expectError(error.InvalidResourcePath, doc.setImage("../invalid.png", 2, 1));
    try std.testing.expectEqual(before.fingerprint(), doc.fingerprint());
    try std.testing.expectEqual(before.nodeIdHighWater(), doc.nodeIdHighWater());
    try std.testing.expectError(error.InvalidSize, doc.setImage("source.png", 0, 1));
    try std.testing.expectEqual(before.fingerprint(), doc.fingerprint());
}

test "non-finite public edits and parsed parameters fail before mutation" {
    var doc = Document.initDefault();
    const before = doc.fingerprint();
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |value| {
        try std.testing.expectError(error.InvalidGain, doc.setGain(1, value));
        try std.testing.expectError(error.InvalidOpacity, doc.addOver(0, 1, value));
    }
    try std.testing.expectEqual(before, doc.fingerprint());
    const id = try doc.addOver(0, 1, 0.5);
    const with_over = doc.fingerprint();
    try std.testing.expectError(error.InvalidOpacity, doc.setOverOpacity(id, std.math.nan(f32)));
    try std.testing.expectEqual(with_over, doc.fingerprint());
    try std.testing.expectError(error.InvalidGain, parse("c0=testsrc{}\nc1=gain{ in:c0,value:nan }\n"));
    try std.testing.expectError(error.InvalidGain, parse("c0=testsrc{}\nc1=gain{ in:c0,value:inf }\n"));
    try std.testing.expectError(error.InvalidNode, parse("c0=testsrc{}\nc1=over{ .{in:c0,x:nan}, .{in:c0} }\n"));
    try std.testing.expectError(error.InvalidNode, parse("c0=testsrc{}\nc1=over{ .{in:c0}, .{in:c0,y:inf} }\n"));
    try std.testing.expectError(error.InvalidNode, parse("c0=testsrc{}\nc1=over{ .{in:c0,opacity:nan}, .{in:c0} }\n"));
}
