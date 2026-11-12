//! capabilities.zig — 内置能力声明、实现注册对账与媒体失败分类
//!
//! ready 只表示实现已静态接入,不表示任意输入都能成功。声明不住在实现表里,
//! implemented 由 render/image 的 adapter_ids 计算;未知能力不是 ready。

const std = @import("std");
const documents = @import("vne").documents;
const render = @import("render.zig");
const image = @import("image.zig");

pub const Domain = enum { node, codec };

pub const Capability = struct {
    id: []const u8,
    domain: Domain,
};

pub const declarations = [_]Capability{
    .{ .id = "node.testsrc", .domain = .node },
    .{ .id = "node.gain", .domain = .node },
    .{ .id = "node.invert", .domain = .node },
    .{ .id = "node.over", .domain = .node },
    .{ .id = "node.resize", .domain = .node },
    .{ .id = "image.png.decode", .domain = .codec },
    .{ .id = "image.png.encode", .domain = .codec },
};

const adapter_ids = render.adapter_ids ++ image.adapter_ids;

pub const Status = enum { ready, not_ready, unsupported };

pub const Audit = struct {
    declared_without_adapter: usize = 0,
    adapter_without_declaration: usize = 0,
    duplicate_declarations: usize = 0,
    duplicate_adapters: usize = 0,

    pub fn ok(self: Audit) bool {
        return self.declared_without_adapter == 0 and
            self.adapter_without_declaration == 0 and
            self.duplicate_declarations == 0 and
            self.duplicate_adapters == 0;
    }
};

fn findDeclaration(items: []const Capability, id: []const u8) ?Capability {
    for (items) |item| {
        if (std.mem.eql(u8, item.id, id)) return item;
    }
    return null;
}

fn containsId(items: []const []const u8, id: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, id)) return true;
    }
    return false;
}

fn auditLists(declared: []const Capability, adapters: []const []const u8) Audit {
    var result: Audit = .{};
    for (declared, 0..) |item, i| {
        if (findDeclaration(declared[0..i], item.id) != null) result.duplicate_declarations += 1;
        if (!containsId(adapters, item.id)) result.declared_without_adapter += 1;
    }
    for (adapters, 0..) |id, i| {
        if (findDeclaration(declared, id) == null) result.adapter_without_declaration += 1;
        if (containsId(adapters[0..i], id)) result.duplicate_adapters += 1;
    }
    return result;
}

pub fn status(id: []const u8) Status {
    if (findDeclaration(&declarations, id) == null) return .unsupported;
    return if (containsId(&adapter_ids, id)) .ready else .not_ready;
}

pub const Report = struct {
    entries: [declarations.len]Entry,
    audit: Audit,

    pub const Entry = struct {
        capability: Capability,
        status: Status,
    };
};

pub fn inspect() Report {
    var result: Report = .{
        .entries = undefined,
        .audit = auditLists(&declarations, &adapter_ids),
    };
    for (declarations, 0..) |item, i| {
        result.entries[i] = .{ .capability = item, .status = status(item.id) };
    }
    return result;
}

pub fn forOp(op: documents.Op) []const u8 {
    return switch (op) {
        .testsrc => "node.testsrc",
        .gain => "node.gain",
        .invert => "node.invert",
        .over => "node.over",
        .resize => "node.resize",
        .image => "image.png.decode",
    };
}

pub const Failure = enum {
    invalid_input,
    missing,
    unsupported,
    no_handler,
    not_ready,
    corrupt,
    failed,
    cancelled,
};

pub fn classifyError(err: anyerror) Failure {
    return switch (err) {
        error.InvalidResourcePath => .invalid_input,
        error.FileNotFound => .missing,
        error.UnsupportedImageFormat => .unsupported,
        error.NoHandler => .no_handler,
        error.ImageIoRequired, error.ImageDirectoryRequired, error.ImageNotLoaded => .not_ready,
        error.TruncatedImage, error.InvalidImageSize => .corrupt,
        error.Cancelled => .cancelled,
        else => .failed,
    };
}

test "built-in declarations and adapters reconcile" {
    const report = inspect();
    try std.testing.expect(report.audit.ok());
    try std.testing.expectEqual(declarations.len, adapter_ids.len);
    for (report.entries) |entry| try std.testing.expectEqual(Status.ready, entry.status);
    try std.testing.expectEqual(Status.unsupported, status("video.decode"));
}

test "every document op resolves to a declared ready capability" {
    inline for (@typeInfo(documents.Op).@"enum".field_values) |value| {
        const op: documents.Op = @fromBackingInt(@intCast(value));
        const id = forOp(op);
        try std.testing.expect(findDeclaration(&declarations, id) != null);
        try std.testing.expectEqual(Status.ready, status(id));
    }
}

test "audit deliberately detects missing undeclared and duplicate entries" {
    const declared = [_]Capability{
        .{ .id = "one", .domain = .node },
        .{ .id = "one", .domain = .node },
        .{ .id = "missing", .domain = .codec },
    };
    const adapters = [_][]const u8{ "one", "one", "extra" };
    const result = auditLists(&declared, &adapters);
    try std.testing.expect(!result.ok());
    try std.testing.expectEqual(@as(usize, 1), result.declared_without_adapter);
    try std.testing.expectEqual(@as(usize, 1), result.adapter_without_declaration);
    try std.testing.expectEqual(@as(usize, 1), result.duplicate_declarations);
    try std.testing.expectEqual(@as(usize, 1), result.duplicate_adapters);
}

test "media failures preserve unsupported missing corrupt and readiness" {
    try std.testing.expectEqual(Failure.unsupported, classifyError(error.UnsupportedImageFormat));
    try std.testing.expectEqual(Failure.missing, classifyError(error.FileNotFound));
    try std.testing.expectEqual(Failure.corrupt, classifyError(error.TruncatedImage));
    try std.testing.expectEqual(Failure.not_ready, classifyError(error.ImageNotLoaded));
    try std.testing.expectEqual(Failure.failed, classifyError(error.ImageDecodeFailed));
    try std.testing.expectEqual(Failure.cancelled, classifyError(error.Cancelled));
}
