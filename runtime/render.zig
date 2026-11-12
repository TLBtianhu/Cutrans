//! render.zig — 最小同步单帧 DAG 求值:testsrc/gain/invert/over/image/resize → RGBA8
//!
//! 无泵、无 L1/L2、无后台任务。Preview 只保留一个当前工作帧,文档指纹变化
//! 才重算;它不是完整流协议或缓存系统。

const std = @import("std");
const documents = @import("vne").documents;
const image = @import("image.zig");

pub const adapter_ids = [_][]const u8{ "node.testsrc", "node.gain", "node.invert", "node.over", "node.resize" };

pub const Frame = @import("vne").frame.Frame;

pub const Source = struct {
    image: image.Image,
    lease: u64,
};

pub const SourceProvider = struct {
    context: *anyopaque,
    load: *const fn (*anyopaque, documents.Node) anyerror!Source,
    release: *const fn (*anyopaque, u64) void,
};

const Lease = struct {
    provider: SourceProvider,
    handle: u64,
};

pub const Preview = struct {
    frame: ?Frame = null,
    fingerprint: u64 = 0,
    evaluation_count: u64 = 0,
    io: ?std.Io = null,
    dir: ?std.Io.Dir = null,
    provider: ?SourceProvider = null,
    leases: [8]Lease = undefined,
    lease_count: usize = 0,
    cancel: ?*const std.atomic.Value(bool) = null,

    pub fn deinit(self: *Preview, allocator: std.mem.Allocator) void {
        if (self.frame) |*frame| frame.deinit(allocator);
        self.releaseLeases();
        self.frame = null;
        self.fingerprint = 0;
        self.io = null;
        self.dir = null;
        self.provider = null;
        self.cancel = null;
    }

    fn releaseLeases(self: *Preview) void {
        for (self.leases[0..self.lease_count]) |lease| lease.provider.release(lease.provider.context, lease.handle);
        self.lease_count = 0;
    }

    pub fn current(self: *Preview, doc: *const documents.Document, allocator: std.mem.Allocator) !*const Frame {
        try checkCancelled(self.cancel);
        const fingerprint = doc.fingerprint();
        if (self.frame != null and self.fingerprint == fingerprint) return &self.frame.?;
        const next = try evaluateCancelable(doc, allocator, self.io, self.dir, self.provider, self.cancel);
        if (self.frame) |*old| old.deinit(allocator);
        self.releaseLeases();
        self.leases = next.leases;
        self.lease_count = next.lease_count;
        self.evaluation_count += 1;
        self.frame = .{
            .width = next.width,
            .height = next.height,
            .generation = self.evaluation_count,
            .pixels = next.pixels,
        };
        self.fingerprint = fingerprint;
        return &self.frame.?;
    }

    pub fn currentWithProvider(self: *Preview, doc: *const documents.Document, allocator: std.mem.Allocator, provider: SourceProvider) !*const Frame {
        if (self.lease_count != 0 and self.provider.?.context != provider.context) return error.SourceProviderMismatch;
        self.provider = provider;
        return self.current(doc, allocator);
    }

    pub fn currentWithDir(self: *Preview, doc: *const documents.Document, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !*const Frame {
        if (self.lease_count != 0) return error.SourceProviderMismatch;
        self.provider = null;
        self.io = io;
        self.dir = dir;
        return self.current(doc, allocator);
    }
};

fn workspaceLoad(ptr: *anyopaque, node: documents.Node) !Source {
    const ctx: *@import("context.zig").Context = @ptrCast(@alignCast(ptr));
    const handle = try ctx.assets.openVersion(ctx, node.asset(), if (node.asset_hash_present) node.asset_hash else null);
    errdefer ctx.assets.release(handle) catch {};
    const asset = try ctx.assets.get(handle);
    if (node.asset_hash_present and !std.mem.eql(u8, &node.asset_hash, &asset.source.content_hash)) return error.SourceContentMismatch;
    return .{ .image = try image.decode(ctx.allocator, asset.bytes), .lease = handle };
}

fn workspaceRelease(ptr: *anyopaque, handle: u64) void {
    const ctx: *@import("context.zig").Context = @ptrCast(@alignCast(ptr));
    ctx.assets.release(handle) catch |err| std.debug.print("[assets] 渲染租约释放失败: {s}\n", .{@errorName(err)});
}

pub fn workspaceProvider(ctx: *@import("context.zig").Context) SourceProvider {
    return .{ .context = ctx, .load = workspaceLoad, .release = workspaceRelease };
}

const Evaluated = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    node_evaluations: [8]u64,
    leases: [8]Lease,
    lease_count: usize,
};

fn channel(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

fn findNode(doc: *const documents.Document, id: u64) ?documents.Node {
    for (doc.nodes[0..doc.count]) |node| {
        if (node.id == id) return node;
    }
    return null;
}

fn findNodeIndex(doc: *const documents.Document, id: u64) ?usize {
    for (doc.nodes[0..doc.count], 0..) |node, i| {
        if (node.id == id) return i;
    }
    return null;
}

const Size = struct { width: u32, height: u32 };

fn compSize(doc: *const documents.Document, assets: []const ?image.Image, id: u64, depth: usize) !Size {
    if (depth > doc.count) return error.CyclicReference;
    const node = findNode(doc, id) orelse return error.InvalidReference;
    switch (node.op) {
        .testsrc => return .{ .width = doc.width, .height = doc.height },
        .gain, .invert => {
            const input = node.unaryInput() orelse return error.InvalidNode;
            return compSize(doc, assets, input, depth + 1);
        },
        .over => {
            if (node.aggCount() != 2) return error.InvalidNode;
            const bottom = try compSize(doc, assets, node.aggInput(0).?, depth + 1);
            const top = try compSize(doc, assets, node.aggInput(1).?, depth + 1);
            if (bottom.width != top.width or bottom.height != top.height) return error.FormatMismatch;
            return bottom;
        },
        .image => {
            const index = findNodeIndex(doc, id) orelse return error.InvalidReference;
            const loaded = assets[index] orelse return error.ImageNotLoaded;
            return .{ .width = loaded.width, .height = loaded.height };
        },
        .resize => return .{ .width = node.out_w, .height = node.out_h },
    }
}

fn evalScalar(doc: *const documents.Document, assets: []const ?image.Image, id: u64, x: usize, y: usize, depth: usize) ![4]f32 {
    if (depth > doc.count) return error.CyclicReference;
    const node = findNode(doc, id) orelse return error.InvalidReference;
    switch (node.op) {
        .testsrc => {
            const t = if (doc.width > 1) @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(doc.width - 1)) else 0;
            return .{
                0.125 + (0.875 - 0.125) * t,
                0.375 + (0.5 - 0.375) * t,
                0.75 + (0.125 - 0.75) * t,
                1,
            };
        },
        .gain => {
            const input = node.unaryInput() orelse return error.InvalidNode;
            var rgba = try evalScalar(doc, assets, input, x, y, depth + 1);
            for (0..3) |c| rgba[c] *= node.value;
            return rgba;
        },
        .invert => {
            const input = node.unaryInput() orelse return error.InvalidNode;
            var rgba = try evalScalar(doc, assets, input, x, y, depth + 1);
            for (0..3) |c| rgba[c] = 1 - rgba[c];
            return rgba;
        },
        .over => {
            if (node.aggCount() != 2) return error.InvalidNode;
            const bottom = try evalScalar(doc, assets, node.aggInput(0).?, x, y, depth + 1);
            const top = try evalScalar(doc, assets, node.aggInput(1).?, x, y, depth + 1);
            const top_alpha = top[3] * node.topOpacity();
            const out_alpha = top_alpha + bottom[3] * (1 - top_alpha);
            if (out_alpha == 0) return .{ 0, 0, 0, 0 };
            var rgba: [4]f32 = undefined;
            for (0..3) |c| rgba[c] = (top[c] * top_alpha + bottom[c] * bottom[3] * (1 - top_alpha)) / out_alpha;
            rgba[3] = out_alpha;
            return rgba;
        },
        .image => {
            const index = findNodeIndex(doc, id) orelse return error.InvalidReference;
            const loaded = assets[index] orelse return error.ImageNotLoaded;
            const offset = (y * @as(usize, loaded.width) + x) * 4;
            var rgba: [4]f32 = undefined;
            for (0..4) |c| rgba[c] = @as(f32, @floatFromInt(loaded.pixels[offset + c])) / 255;
            return rgba;
        },
        .resize => {
            const input = node.unaryInput() orelse return error.InvalidNode;
            if (node.out_w == 0 or node.out_h == 0) return error.InvalidSize;
            const input_size = try compSize(doc, assets, input, depth + 1);
            const source_x = x * @as(usize, input_size.width) / @as(usize, node.out_w);
            const source_y = y * @as(usize, input_size.height) / @as(usize, node.out_h);
            return evalScalar(doc, assets, input, source_x, source_y, depth + 1);
        },
    }
}

fn allocFrame(allocator: std.mem.Allocator, width: u32, height: u32) !Frame {
    const count = try std.math.mul(usize, @as(usize, width), @as(usize, height));
    return .{
        .width = width,
        .height = height,
        .generation = 0,
        .pixels = try allocator.alloc(u8, try std.math.mul(usize, count, 4)),
    };
}

fn checkCancelled(cancel: ?*const std.atomic.Value(bool)) !void {
    if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
}

fn cloneFrame(allocator: std.mem.Allocator, source: *const Frame, cancel: ?*const std.atomic.Value(bool)) !Frame {
    try checkCancelled(cancel);
    var result = try allocFrame(allocator, source.width, source.height);
    errdefer result.deinit(allocator);
    var offset: usize = 0;
    while (offset < source.pixels.len) {
        try checkCancelled(cancel);
        const end = @min(offset + 64 * 1024, source.pixels.len);
        @memcpy(result.pixels[offset..end], source.pixels[offset..end]);
        offset = end;
    }
    try checkCancelled(cancel);
    return result;
}

const EvalContext = struct {
    doc: *const documents.Document,
    assets: []const ?image.Image,
    allocator: std.mem.Allocator,
    frames: [8]?Frame,
    node_evaluations: [8]u64,
    cancel: ?*const std.atomic.Value(bool),

    fn init(doc: *const documents.Document, assets: []const ?image.Image, allocator: std.mem.Allocator, cancel: ?*const std.atomic.Value(bool)) EvalContext {
        return .{
            .doc = doc,
            .assets = assets,
            .allocator = allocator,
            .cancel = cancel,
            .frames = .{ null, null, null, null, null, null, null, null },
            .node_evaluations = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        };
    }

    fn deinit(self: *EvalContext) void {
        for (&self.frames) |*frame| {
            if (frame.*) |*value| value.deinit(self.allocator);
        }
    }

    fn frameForIndex(self: *EvalContext, index: usize, depth: usize) anyerror!*const Frame {
        try checkCancelled(self.cancel);
        if (self.frames[index]) |*frame| return frame;
        if (depth > self.doc.count) return error.CyclicReference;
        const frame = try self.produce(index, depth);
        self.frames[index] = frame;
        self.node_evaluations[index] += 1;
        return &self.frames[index].?;
    }

    fn produce(self: *EvalContext, index: usize, depth: usize) anyerror!Frame {
        const node = self.doc.nodes[index];
        switch (node.op) {
            .testsrc => {
                var output = try allocFrame(self.allocator, self.doc.width, self.doc.height);
                errdefer output.deinit(self.allocator);
                for (0..self.doc.height) |y| {
                    try checkCancelled(self.cancel);
                    for (0..self.doc.width) |x| {
                        if (x % 256 == 0) try checkCancelled(self.cancel);
                        const t = if (self.doc.width > 1) @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(self.doc.width - 1)) else 0;
                        const rgba = [4]f32{
                            0.125 + (0.875 - 0.125) * t,
                            0.375 + (0.5 - 0.375) * t,
                            0.75 + (0.125 - 0.75) * t,
                            1,
                        };
                        const offset = (y * @as(usize, self.doc.width) + x) * 4;
                        for (0..4) |c| output.pixels[offset + c] = channel(rgba[c]);
                    }
                }
                return output;
            },
            .gain, .invert => {
                var chain: [8]documents.Node = undefined;
                var count: usize = 0;
                var source_id = node.id;
                while (true) {
                    const current = findNode(self.doc, source_id) orelse return error.InvalidReference;
                    if (current.op != .gain and current.op != .invert) break;
                    chain[count] = current;
                    count += 1;
                    source_id = current.unaryInput() orelse return error.InvalidNode;
                }
                const source_index = findNodeIndex(self.doc, source_id) orelse return error.InvalidReference;
                if (self.doc.nodes[source_index].op == .testsrc) {
                    var output = try allocFrame(self.allocator, self.doc.width, self.doc.height);
                    errdefer output.deinit(self.allocator);
                    for (0..self.doc.height) |y| {
                        try checkCancelled(self.cancel);
                        for (0..self.doc.width) |x| {
                            if (x % 256 == 0) try checkCancelled(self.cancel);
                            const rgba = try evalScalar(self.doc, self.assets, node.id, x, y, 0);
                            const offset = (y * @as(usize, self.doc.width) + x) * 4;
                            for (0..4) |c| output.pixels[offset + c] = channel(rgba[c]);
                        }
                    }
                    return output;
                }
                const source = try self.frameForIndex(source_index, depth + 1);
                var output = try cloneFrame(self.allocator, source, self.cancel);
                errdefer output.deinit(self.allocator);
                var chain_index = count;
                while (chain_index > 0) {
                    chain_index -= 1;
                    const current = chain[chain_index];
                    switch (current.op) {
                        .gain => {
                            for (0..output.pixels.len) |i| {
                                if (i % 4096 == 0) try checkCancelled(self.cancel);
                                if (i % 4 != 3) output.pixels[i] = channel(@as(f32, @floatFromInt(output.pixels[i])) / 255 * current.value);
                            }
                        },
                        .invert => {
                            for (0..output.pixels.len) |i| {
                                if (i % 4096 == 0) try checkCancelled(self.cancel);
                                if (i % 4 != 3) output.pixels[i] = 255 - output.pixels[i];
                            }
                        },
                        else => unreachable,
                    }
                }
                return output;
            },
            .over => {
                if (node.aggCount() != 2) return error.InvalidNode;
                const bottom = try self.frameForIndex(findNodeIndex(self.doc, node.aggInput(0).?).?, depth + 1);
                _ = try self.frameForIndex(findNodeIndex(self.doc, node.aggInput(1).?).?, depth + 1);
                var output = try allocFrame(self.allocator, bottom.width, bottom.height);
                errdefer output.deinit(self.allocator);
                for (0..bottom.height) |y| {
                    try checkCancelled(self.cancel);
                    for (0..bottom.width) |x| {
                        if (x % 256 == 0) try checkCancelled(self.cancel);
                        const rgba = try evalScalar(self.doc, self.assets, node.id, x, y, 0);
                        const offset = (y * @as(usize, bottom.width) + x) * 4;
                        for (0..4) |c| output.pixels[offset + c] = channel(rgba[c]);
                    }
                }
                return output;
            },
            .image => {
                const loaded = self.assets[index] orelse return error.ImageNotLoaded;
                return cloneFrame(self.allocator, &.{ .width = loaded.width, .height = loaded.height, .generation = 0, .pixels = loaded.pixels }, self.cancel);
            },
            .resize => {
                const input_id = node.unaryInput() orelse return error.InvalidNode;
                if (node.out_w == 0 or node.out_h == 0) return error.InvalidSize;
                const input = try self.frameForIndex(findNodeIndex(self.doc, input_id).?, depth + 1);
                var output = try allocFrame(self.allocator, node.out_w, node.out_h);
                errdefer output.deinit(self.allocator);
                for (0..node.out_h) |y| {
                    try checkCancelled(self.cancel);
                    for (0..node.out_w) |x| {
                        if (x % 256 == 0) try checkCancelled(self.cancel);
                        const source_x = x * @as(usize, input.width) / @as(usize, node.out_w);
                        const source_y = y * @as(usize, input.height) / @as(usize, node.out_h);
                        const source_offset = (source_y * @as(usize, input.width) + source_x) * 4;
                        const output_offset = (y * @as(usize, node.out_w) + x) * 4;
                        for (0..4) |c| output.pixels[output_offset + c] = input.pixels[source_offset + c];
                    }
                }
                return output;
            },
        }
    }
};

fn evaluate(doc: *const documents.Document, allocator: std.mem.Allocator, io: ?std.Io, dir: ?std.Io.Dir, provider: ?SourceProvider) !Evaluated {
    return evaluateCancelable(doc, allocator, io, dir, provider, null);
}

fn evaluateCancelable(doc: *const documents.Document, allocator: std.mem.Allocator, io: ?std.Io, dir: ?std.Io.Dir, provider: ?SourceProvider, cancel: ?*const std.atomic.Value(bool)) !Evaluated {
    try checkCancelled(cancel);
    if (doc.count == 0) return error.EmptyDocument;
    const output_id = doc.outputId() orelse return error.EmptyDocument;
    var assets: [8]?image.Image = .{ null, null, null, null, null, null, null, null };
    defer for (&assets) |*asset| {
        if (asset.*) |*loaded| loaded.deinit(allocator);
    };
    var leases: [8]Lease = undefined;
    var lease_count: usize = 0;
    errdefer for (leases[0..lease_count]) |lease| lease.provider.release(lease.provider.context, lease.handle);
    for (doc.nodes[0..doc.count], 0..) |node, i| {
        try checkCancelled(cancel);
        if (node.op == .image) {
            if (provider) |source_provider| {
                const source = try source_provider.load(source_provider.context, node);
                leases[lease_count] = .{ .provider = source_provider, .handle = source.lease };
                lease_count += 1;
                assets[i] = source.image;
            } else {
                const io_value = io orelse return error.ImageIoRequired;
                const dir_value = dir orelse return error.ImageDirectoryRequired;
                assets[i] = try image.load(allocator, io_value, dir_value, node.asset());
            }
        }
        try checkCancelled(cancel);
    }
    const output_size = try compSize(doc, &assets, output_id, 0);
    if (output_size.width != doc.width or output_size.height != doc.height) return error.FormatMismatch;

    var ctx = EvalContext.init(doc, &assets, allocator, cancel);
    defer ctx.deinit();
    const frame = try ctx.frameForIndex(findNodeIndex(doc, output_id).?, 0);
    const copied = try cloneFrame(allocator, frame, cancel);
    return .{
        .width = frame.width,
        .height = frame.height,
        .pixels = copied.pixels,
        .node_evaluations = ctx.node_evaluations,
        .leases = leases,
        .lease_count = lease_count,
    };
}

test "testsrc and gain produce exact RGBA pixels" {
    var doc = documents.Document.initDefault();
    doc.width = 4;
    doc.height = 2;
    var preview: Preview = .{};
    defer preview.deinit(std.testing.allocator);
    const frame = try preview.current(&doc, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4 * 2 * 4), frame.pixels.len);
    try std.testing.expectEqualSlices(u8, &.{ 26, 77, 153, 255 }, frame.pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 179, 102, 26, 255 }, frame.pixels[12..16]);
    try std.testing.expectEqual(@as(u64, 1), preview.evaluation_count);
    _ = try preview.current(&doc, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), preview.evaluation_count);
}

test "document changes invalidate only the current frame" {
    var doc = documents.Document.initDefault();
    doc.width = 2;
    doc.height = 1;
    var preview: Preview = .{};
    defer preview.deinit(std.testing.allocator);
    const before = doc.fingerprint();
    _ = try preview.current(&doc, std.testing.allocator);
    try doc.setGain(1, 0.5);
    try std.testing.expect(before != doc.fingerprint());
    const frame = try preview.current(&doc, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), preview.evaluation_count);
    try std.testing.expectEqual(@as(u64, 2), frame.generation);
    try std.testing.expectEqualSlices(u8, &.{ 16, 48, 96, 255 }, frame.pixels[0..4]);
    const after = doc.fingerprint();
    doc.dirty = false;
    try std.testing.expectEqual(after, doc.fingerprint());
    _ = try preview.current(&doc, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), preview.evaluation_count);
}

test "resolution changes produce a new frame and generation" {
    var doc = documents.Document.initDefault();
    doc.width = 2;
    doc.height = 1;
    var preview: Preview = .{};
    defer preview.deinit(std.testing.allocator);
    _ = try preview.current(&doc, std.testing.allocator);
    doc.width = 4;
    doc.height = 2;
    const frame = try preview.current(&doc, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), frame.width);
    try std.testing.expectEqual(@as(u32, 2), frame.height);
    try std.testing.expectEqual(@as(usize, 32), frame.pixels.len);
    try std.testing.expectEqual(@as(u64, 2), preview.evaluation_count);
    try std.testing.expectEqual(@as(u64, 2), frame.generation);
}

test "edit save reopen and evaluate preserve the same pixels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var doc = documents.Document.initDefault();
    doc.width = 2;
    doc.height = 1;
    try doc.setGain(1, 0.25);
    try documents.save(&doc, std.testing.io, std.testing.allocator, tmp.dir, "session.cut");
    var restored = documents.Document.initDefault();
    try documents.open(&restored, std.testing.io, std.testing.allocator, tmp.dir, "session.cut");
    var preview: Preview = .{};
    defer preview.deinit(std.testing.allocator);
    const frame = try preview.current(&restored, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 8, 24, 48, 255 }, frame.pixels[0..4]);
    try std.testing.expectEqual(doc.fingerprint(), restored.fingerprint());
}

test "over evaluates both branches by comp id" {
    var doc = documents.Document.initDefault();
    doc.width = 1;
    doc.height = 1;
    doc.count = 3;
    doc.output_id = 2;
    doc.nodes[1] = .{ .id = 1, .op = .invert, .birth = .{ .transform = 0 } };
    doc.nodes[2] = .{ .id = 2, .op = .over, .birth = .{ .aggregate = .{ .items = .{ .{ .input = 0 }, .{ .input = 1, .opacity = 0.25 } }, .count = 2 } } };
    var preview: Preview = .{};
    defer preview.deinit(std.testing.allocator);
    const frame = try preview.current(&doc, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 80, 112, 159, 255 }, frame.pixels[0..4]);
}

test "shared inputs are evaluated once per demand" {
    var doc = documents.Document.initDefault();
    doc.width = 1;
    doc.height = 1;
    doc.count = 3;
    doc.output_id = 2;
    doc.nodes[1] = .{ .id = 1, .op = .invert, .birth = .{ .transform = 0 } };
    doc.nodes[2] = .{ .id = 2, .op = .over, .birth = .{ .aggregate = .{ .items = .{ .{ .input = 0 }, .{ .input = 1, .opacity = 0.25 } }, .count = 2 } } };
    const evaluated = try evaluate(&doc, std.testing.allocator, null, null, null);
    defer std.testing.allocator.free(evaluated.pixels);
    try std.testing.expectEqual(@as(u64, 1), evaluated.node_evaluations[0]);
    try std.testing.expectEqual(@as(u64, 1), evaluated.node_evaluations[1]);
    try std.testing.expectEqual(@as(u64, 1), evaluated.node_evaluations[2]);
}

test "gain invert and over compose with exact pixels" {
    var doc = documents.Document.initDefault();
    doc.width = 1;
    doc.height = 1;
    try doc.setGain(1, 0.25);
    _ = try doc.addInvert(1);
    _ = try doc.addOver(0, 2, 0.25);
    const evaluated = try evaluate(&doc, std.testing.allocator, null, null, null);
    defer std.testing.allocator.free(evaluated.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 86, 129, 195, 255 }, evaluated.pixels[0..4]);
}

test "evaluation rejects a missing comp reference" {
    var doc = documents.Document.initDefault();
    doc.width = 1;
    doc.height = 1;
    doc.nodes[1].birth = .{ .transform = 99 };
    var preview: Preview = .{};
    defer preview.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidReference, preview.current(&doc, std.testing.allocator));
}

test "resize duplicates nearest pixels on both axes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source = image.Image{
        .width = 2,
        .height = 1,
        .pixels = try std.testing.allocator.dupe(u8, &.{ 10, 20, 30, 255, 100, 110, 120, 128 }),
    };
    defer source.deinit(std.testing.allocator);
    try image.savePng(std.testing.allocator, std.testing.io, tmp.dir, "source.png", source);

    var doc = documents.Document.initDefault();
    try doc.setImage("source.png", 2, 1);
    _ = try doc.addResize(doc.outputId().?, 4, 2);
    var preview: Preview = .{};
    defer preview.deinit(std.testing.allocator);
    const frame = try preview.currentWithDir(&doc, std.testing.allocator, std.testing.io, tmp.dir);
    try std.testing.expectEqual(@as(u32, 4), frame.width);
    try std.testing.expectEqual(@as(u32, 2), frame.height);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, frame.pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, frame.pixels[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 100, 110, 120, 128 }, frame.pixels[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 100, 110, 120, 128 }, frame.pixels[12..16]);
    try std.testing.expectEqualSlices(u8, frame.pixels[0..16], frame.pixels[16..32]);
}

test "snapshot providers share leases and reload from Source after the Station is empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "source.png" });
    defer std.testing.allocator.free(source_path);
    var pixels = [_]u8{ 1, 2, 3, 255 };
    try image.savePngExternal(std.testing.allocator, std.testing.io, source_path, .{ .width = 1, .height = 1, .pixels = &pixels });
    var ctx: @import("context.zig").Context = undefined;
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.io = std.testing.io;
    ctx.paths = try @import("paths.zig").Paths.fromDirs(std.testing.allocator, .development, resource, data);
    try @import("mounts.zig").configure(&ctx);
    _ = try ctx.mounts.grantExternal(std.testing.allocator, source_path, .read_only);
    const external = try ctx.assets.open(&ctx, "external://1");
    try ctx.assets.exportSnapshot(external, "session://snapshots/one");
    try ctx.assets.release(external);
    const snapshot = try ctx.assets.open(&ctx, "session://snapshots/one");
    const digest = (try ctx.assets.get(snapshot)).source.content_hash;
    try std.Io.Dir.cwd().deleteFile(std.testing.io, source_path);
    var doc = documents.Document.initDefault();
    try doc.setImageSource("session://snapshots/one", digest, 1, 1);
    {
        var preview: Preview = .{};
        defer preview.deinit(std.testing.allocator);
        const frame = try preview.currentWithProvider(&doc, std.testing.allocator, workspaceProvider(&ctx));
        try std.testing.expectEqualSlices(u8, &pixels, frame.pixels);
        try std.testing.expectEqual(@as(u32, 2), (try ctx.assets.get(snapshot)).leases);
        try ctx.assets.release(snapshot);
        try std.testing.expectEqual(@as(u32, 1), (try ctx.assets.get(snapshot)).leases);
        try std.testing.expectEqualSlices(u8, &pixels, frame.pixels);
    }
    try std.testing.expectEqual(@as(usize, 0), ctx.assets.count);
    var restored: Preview = .{};
    defer restored.deinit(std.testing.allocator);
    const frame = try restored.currentWithProvider(&doc, std.testing.allocator, workspaceProvider(&ctx));
    try std.testing.expectEqualSlices(u8, &pixels, frame.pixels);
    try std.testing.expectEqual(@as(usize, 1), ctx.assets.count);
    try std.testing.expectEqual(@as(u32, 1), ctx.assets.items[0].leases);
}

test "cancellation before and after Source load releases owned pixels and lease" {
    const Provider = struct {
        cancel: *std.atomic.Value(bool),
        loads: usize = 0,
        releases: usize = 0,

        fn load(pointer: *anyopaque, _: documents.Node) !Source {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.loads += 1;
            const pixels = try std.testing.allocator.dupe(u8, &.{ 1, 2, 3, 255 });
            self.cancel.store(true, .release);
            return .{ .image = .{ .width = 1, .height = 1, .pixels = pixels }, .lease = 42 };
        }

        fn release(pointer: *anyopaque, lease: u64) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            std.debug.assert(lease == 42);
            self.releases += 1;
        }
    };
    var cancel = std.atomic.Value(bool).init(true);
    var source = Provider{ .cancel = &cancel };
    var doc = documents.Document.initDefault();
    try doc.setImageSource("pack://assets/example.png", @as([32]u8, @splat(0)), 1, 1);
    var preview: Preview = .{ .cancel = &cancel };
    defer preview.deinit(std.testing.allocator);
    const provider = SourceProvider{ .context = &source, .load = Provider.load, .release = Provider.release };
    try std.testing.expectError(error.Cancelled, preview.currentWithProvider(&doc, std.testing.allocator, provider));
    try std.testing.expectEqual(@as(usize, 0), source.loads);
    cancel.store(false, .release);
    try std.testing.expectError(error.Cancelled, preview.currentWithProvider(&doc, std.testing.allocator, provider));
    try std.testing.expectEqual(@as(usize, 1), source.loads);
    try std.testing.expectEqual(@as(usize, 1), source.releases);
    try std.testing.expectEqual(@as(usize, 0), preview.lease_count);
    try std.testing.expect(preview.frame == null);
    try std.testing.expectEqual(@as(u64, 0), preview.evaluation_count);
}

test "row and frame-copy cancellation unwind allocations and preserve current frame" {
    // Allocation is the deterministic barrier: cancellation becomes visible
    // after frame allocation, before the first row/copy, without a timer.
    const CancellingAllocator = struct {
        token: *std.atomic.Value(bool),
        allocations: usize = 0,
        frees: usize = 0,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }

        fn alloc(pointer: *anyopaque, length: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            const result = std.testing.allocator.rawAlloc(length, alignment, ret_addr) orelse return null;
            self.allocations += 1;
            self.token.store(true, .release);
            return result;
        }

        fn free(pointer: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.frees += 1;
            std.testing.allocator.rawFree(bytes, alignment, ret_addr);
        }
    };
    var token = std.atomic.Value(bool).init(false);
    var cancelling = CancellingAllocator{ .token = &token };
    var doc = documents.Document.initDefault();
    doc.width = 4;
    doc.height = 2;
    var preview: Preview = .{ .cancel = &token };
    defer preview.deinit(std.testing.allocator);
    _ = try preview.current(&doc, std.testing.allocator);
    const old_pointer = preview.frame.?.pixels.ptr;
    const old_fingerprint = preview.fingerprint;
    try doc.setGain(1, 0.5);
    try std.testing.expectError(error.Cancelled, preview.current(&doc, cancelling.allocator()));
    try std.testing.expectEqual(cancelling.allocations, cancelling.frees);
    try std.testing.expectEqual(@as(usize, 1), cancelling.allocations);
    try std.testing.expectEqual(old_pointer, preview.frame.?.pixels.ptr);
    try std.testing.expectEqual(old_fingerprint, preview.fingerprint);
    try std.testing.expectEqual(@as(u64, 1), preview.evaluation_count);
    token.store(false, .release);
    try std.testing.expectError(error.Cancelled, cloneFrame(cancelling.allocator(), &preview.frame.?, &token));
    try std.testing.expectEqual(cancelling.allocations, cancelling.frees);
    try std.testing.expectEqual(@as(usize, 2), cancelling.allocations);
    token.store(false, .release);
    _ = try preview.current(&doc, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), preview.evaluation_count);
}
