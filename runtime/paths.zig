//! Path boundaries shared through `vne.paths`; this module keeps the
//! Runtime-facing test that needs the document codec.

pub const Paths = @import("vne").paths.Paths;
pub const Mode = @import("vne").paths.Mode;
pub const LaunchOptions = @import("vne").paths.LaunchOptions;
pub const parseMode = @import("vne").paths.parseMode;
pub const parseLaunchArg = @import("vne").paths.parseLaunchArg;
pub const parseLaunchArgs = @import("vne").paths.parseLaunchArgs;

const std = @import("std");
const documents = @import("vne").documents;

test "saving through paths creates a real user document outside resources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource_root = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource_root);
    const data_root = try std.fs.path.join(std.testing.allocator, &.{ root, "user-data" });
    defer std.testing.allocator.free(data_root);
    var paths = try Paths.fromDirs(std.testing.allocator, .development, resource_root, data_root);
    defer paths.deinit(std.testing.allocator);
    var data_dir = try paths.openDataDir(std.testing.io, std.testing.allocator);
    defer data_dir.close(std.testing.io);

    var doc = documents.Document.initDefault();
    try doc.setGain(1, 0.5);
    try documents.save(&doc, std.testing.io, std.testing.allocator, data_dir, "documents/session.cut");
    var restored = documents.Document.initDefault();
    try documents.open(&restored, std.testing.io, std.testing.allocator, data_dir, "documents/session.cut");
    try std.testing.expectEqual(@as(f32, 0.5), restored.nodes[1].value);
    try std.testing.expectEqual(doc.fingerprint(), restored.fingerprint());
}
