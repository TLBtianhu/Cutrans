//! Attempt-owned encoded Sources. Capture runs under the session owner lock;
//! the worker provider never reaches Context, Station, grants or live Catalogs.
const std = @import("std");
const documents = @import("vne").documents;
const image = @import("image.zig");
const render = @import("render.zig");
const Context = @import("context.zig").Context;
const png_limits = @import("png_limits.zig");

pub const max_encoded_bytes = 64 * 1024 * 1024;
pub const max_source_bytes = png_limits.max_encoded_bytes;
pub const max_decoded_bytes = png_limits.max_decoded_bytes;

const Entry = struct {
    node: documents.Node,
    encoded: []u8,
    decoded_bytes: usize,
};

pub const Inputs = struct {
    allocator: std.mem.Allocator,
    entries: [8]Entry = undefined,
    count: usize = 0,
    encoded_bytes: usize = 0,
    decoded_bytes: usize = 0,

    pub fn deinit(self: *Inputs) void {
        for (self.entries[0..self.count]) |entry| self.allocator.free(entry.encoded);
        self.* = undefined;
    }

    /// Keep Inputs at one address until Preview.deinit releases this provider.
    /// The allocator must support the worker thread using and freeing pixels.
    pub fn provider(self: *Inputs) render.SourceProvider {
        return .{ .context = self, .load = load, .release = release };
    }

    fn load(pointer: *anyopaque, node: documents.Node) !render.Source {
        const self: *Inputs = @ptrCast(@alignCast(pointer));
        if (node.op != .image or !node.asset_hash_present or node.asset_len > node.asset_path.len) return error.UnboundExportSource;
        for (self.entries[0..self.count]) |entry| {
            if (entry.node.id != node.id) continue;
            if (!std.mem.eql(u8, entry.node.asset(), node.asset()) or !std.mem.eql(u8, &entry.node.asset_hash, &node.asset_hash))
                return error.SourceContentMismatch;
            var decoded = try image.decode(self.allocator, entry.encoded);
            errdefer decoded.deinit(self.allocator);
            if (decoded.pixels.len != entry.decoded_bytes) return error.SourceDecodeSizeMismatch;
            // render.evaluate owns this new image and calls Image.deinit.
            return .{ .image = decoded, .lease = node.id };
        }
        return error.ExportSourceNotCaptured;
    }

    fn release(_: *anyopaque, _: u64) void {}
};

const decodedPngSize = png_limits.decodedPngSize;

/// The caller holds the session's mutation lock. Only owned Source bytes escape.
/// `budget` is the encoded total for this attempt, capped at the 64 MiB policy.
/// This is a Source budget, not a total renderer/process memory guarantee.
pub fn captureLocked(allocator: std.mem.Allocator, ctx: *Context, doc: *const documents.Document, budget: usize) !Inputs {
    if (doc.count > doc.nodes.len) return error.InvalidDocument;
    var result = Inputs{ .allocator = allocator };
    errdefer result.deinit();
    const encoded_budget = @min(budget, max_encoded_bytes);
    for (doc.nodes[0..doc.count]) |node| {
        if (node.op != .image) continue;
        if (!node.asset_hash_present or node.asset_len > node.asset_path.len) return error.UnboundExportSource;
        for (result.entries[0..result.count]) |entry| if (entry.node.id == node.id) return error.DuplicateExportSource;
        var source = try @import("assets.zig").readVersion(ctx, node.asset(), node.asset_hash);
        defer source.deinit(ctx.allocator);
        if (source.bytes.len > max_source_bytes) return error.ExportEncodedBudgetExceeded;
        const encoded_total = std.math.add(usize, result.encoded_bytes, source.bytes.len) catch return error.ExportEncodedBudgetExceeded;
        if (encoded_total > encoded_budget) return error.ExportEncodedBudgetExceeded;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source.bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &source.source.content_hash) or !std.mem.eql(u8, &digest, &node.asset_hash)) return error.SourceContentMismatch;
        const decoded_size = try decodedPngSize(source.bytes);
        const decoded_total = std.math.add(usize, result.decoded_bytes, decoded_size) catch return error.ExportDecodedBudgetExceeded;
        if (decoded_total > max_decoded_bytes) return error.ExportDecodedBudgetExceeded;
        const encoded = try allocator.dupe(u8, source.bytes);
        result.entries[result.count] = .{ .node = node, .encoded = encoded, .decoded_bytes = decoded_size };
        result.count += 1;
        result.encoded_bytes = encoded_total;
        result.decoded_bytes = decoded_total;
    }
    return result;
}

fn testContext(ctx: *Context, dir: std.Io.Dir) !struct { path: []u8, digest: [32]u8 } {
    const allocator = std.testing.allocator;
    const root = try dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const resource = try std.fs.path.join(allocator, &.{ root, "resources" });
    defer allocator.free(resource);
    const data = try std.fs.path.join(allocator, &.{ root, "data" });
    defer allocator.free(data);
    const source_path = try std.fs.path.join(allocator, &.{ resource, "assets/examples/source.png" });
    errdefer allocator.free(source_path);
    var pixels = [_]u8{ 12, 34, 56, 255 };
    try image.savePngExternal(allocator, std.testing.io, source_path, .{ .width = 1, .height = 1, .pixels = &pixels });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, source_path, allocator, .limited(max_source_bytes));
    defer allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    ctx.init(allocator);
    errdefer ctx.deinit();
    ctx.io = std.testing.io;
    ctx.paths = try @import("paths.zig").Paths.fromDirs(allocator, .development, resource, data);
    try @import("mounts.zig").configure(ctx);
    return .{ .path = source_path, .digest = digest };
}

test "captured Sources outlive Context and file changes and decode independently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var doc = documents.Document.initDefault();
    var inputs: Inputs = undefined;
    {
        var ctx: Context = undefined;
        const source = try testContext(&ctx, tmp.dir);
        defer std.testing.allocator.free(source.path);
        defer ctx.deinit();
        try doc.setImageSource("pack://assets/examples/source.png", source.digest, 1, 1);
        inputs = try captureLocked(std.testing.allocator, &ctx, &doc, max_encoded_bytes);
        try std.testing.expectEqual(@as(usize, 0), ctx.assets.count);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = source.path, .data = "changed after admission" });
    }
    defer inputs.deinit();
    const provider = inputs.provider();
    const node = doc.nodes[0];
    var first = try provider.load(provider.context, node);
    defer first.image.deinit(std.testing.allocator);
    var second = try provider.load(provider.context, node);
    defer second.image.deinit(std.testing.allocator);
    try std.testing.expect(first.image.pixels.ptr != second.image.pixels.ptr);
    first.image.pixels[0] = 0;
    try std.testing.expectEqualSlices(u8, &.{ 12, 34, 56, 255 }, second.image.pixels);
    var preview: render.Preview = .{};
    defer preview.deinit(std.testing.allocator);
    const frame = try preview.currentWithProvider(&doc, std.testing.allocator, provider);
    try std.testing.expectEqualSlices(u8, &.{ 12, 34, 56, 255 }, frame.pixels);
    var changed = node;
    changed.asset_hash[0] ^= 1;
    try std.testing.expectError(error.SourceContentMismatch, provider.load(provider.context, changed));
    changed = node;
    changed.id += 1;
    try std.testing.expectError(error.ExportSourceNotCaptured, provider.load(provider.context, changed));
    changed = node;
    changed.asset_path[0] = 'x';
    try std.testing.expectError(error.SourceContentMismatch, provider.load(provider.context, changed));
}

test "capture rejects source drift and encoded budget before publishing Inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx: Context = undefined;
    const source = try testContext(&ctx, tmp.dir);
    defer std.testing.allocator.free(source.path);
    defer ctx.deinit();
    var doc = documents.Document.initDefault();
    try doc.setImageSource("pack://assets/examples/source.png", source.digest, 1, 1);
    try std.testing.expectError(error.ExportEncodedBudgetExceeded, captureLocked(std.testing.allocator, &ctx, &doc, 1));
    doc.nodes[0].asset_hash[0] ^= 1;
    try std.testing.expectError(error.SourceContentMismatch, captureLocked(std.testing.allocator, &ctx, &doc, max_encoded_bytes));
    doc.nodes[0].asset_hash = source.digest;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = source.path, .data = "source replaced" });
    try std.testing.expectError(error.SourceContentMismatch, captureLocked(std.testing.allocator, &ctx, &doc, max_encoded_bytes));
}

test "capture unwinds partial owned buffers on allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx: Context = undefined;
    const source = try testContext(&ctx, tmp.dir);
    defer std.testing.allocator.free(source.path);
    defer ctx.deinit();
    var doc = documents.Document.initDefault();
    try doc.setImageSource("pack://assets/examples/source.png", source.digest, 1, 1);
    doc.count = 2;
    doc.nodes[1] = doc.nodes[0];
    doc.nodes[1].id += 1;
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, captureLocked(failing.allocator(), &ctx, &doc, max_encoded_bytes));
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try std.testing.expectEqual(@as(usize, 0), ctx.assets.count);
    }
    var inputs = try captureLocked(std.testing.allocator, &ctx, &doc, max_encoded_bytes);
    defer inputs.deinit();
    try std.testing.expectEqual(@as(usize, 2), inputs.count);
}

test "PNG decoded source budget rejects bombs and overflow before decode" {
    var header: [33]u8 = @splat(0);
    @memcpy(header[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, header[8..12], 13, .big);
    @memcpy(header[12..16], "IHDR");
    std.mem.writeInt(u32, header[16..20], 1, .big);
    std.mem.writeInt(u32, header[20..24], 1, .big);
    try std.testing.expectEqual(@as(usize, 4), try decodedPngSize(&header));
    std.mem.writeInt(u32, header[16..20], 4097, .big);
    std.mem.writeInt(u32, header[20..24], 4096, .big);
    try std.testing.expectError(error.ExportDecodedBudgetExceeded, decodedPngSize(&header));
    std.mem.writeInt(u32, header[16..20], 0x7fffffff, .big);
    try std.testing.expectError(error.ExportDecodedBudgetExceeded, decodedPngSize(&header));
    std.mem.writeInt(u32, header[16..20], 0, .big);
    try std.testing.expectError(error.InvalidImageSize, decodedPngSize(&header));
}
