//! Shared command names and their Shell/Runtime classifications.
//!
//! The Runtime registers the handlers, the Shell forwards intents, and the
//! workspace receipt layer only manages a subset. Keeping the names and the
//! classification here prevents those lists from drifting apart silently.

const std = @import("std");

/// Commands the Shell forwards to the Host and the unified Runtime registers.
pub const forwarded = [_][]const u8{
    "doc.open",
    "doc.read",
    "doc.write",
    "doc.save",
    "editor.gain.set",
    "editor.invert.add",
    "editor.over.add",
    "editor.over.opacity.set",
    "editor.image.open",
    "editor.export.png",
    "task.cancel",
    "task.retry",
    "task.list",
    "editor.resize.add",
    "history.undo",
    "history.redo",
    "playback.start",
    "playback.status",
    "playback.stop",
    "asset.open",
    "asset.ensure",
    "resource.acquire",
    "asset.check",
    "asset.preview",
    "asset.export",
    "asset.release",
    "asset.list",
    "source.reauthorize",
    "source.list",
    "library.refresh",
    "library.detach",
    "library.create",
    "library.folder.create",
    "library.rename",
    "library.move",
    "library.remove",
    "library.list",
    "editor.asset.insert",
};

/// Runtime-internal commands that are intentionally not forwarded by the Shell.
pub const runtime_only = [_][]const u8{
    "task.cancel_all",
};

/// Commands that must carry a workspace receipt and client identity/sequence.
pub const managed = [_][]const u8{
    "doc.open",
    "doc.save",
    "doc.write",
    "editor.gain.set",
    "editor.invert.add",
    "editor.over.add",
    "editor.over.opacity.set",
    "editor.resize.add",
    "editor.image.open",
    "editor.asset.insert",
    "editor.export.png",
    "task.retry",
    "history.undo",
    "history.redo",
};

/// Read-only or maintenance commands the Shell may attempt while projections
/// are stale. They must still fail closed when the Host is unavailable.
pub const stale_allowed = [_][]const u8{
    "asset.release",
    "task.cancel",
    "playback.stop",
    "doc.read",
    "task.list",
    "library.list",
    "asset.list",
    "playback.status",
};

/// Managed commands that append a node to the document DAG.
pub const node_creating = [_][]const u8{
    "editor.invert.add",
    "editor.over.add",
    "editor.resize.add",
    "editor.image.open",
    "editor.asset.insert",
};

pub fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

pub fn isForwarded(name: []const u8) bool {
    return contains(&forwarded, name);
}

pub fn isManaged(name: []const u8) bool {
    return contains(&managed, name);
}

pub fn isStaleAllowed(name: []const u8) bool {
    return contains(&stale_allowed, name);
}

pub fn isNodeCreating(name: []const u8) bool {
    return contains(&node_creating, name);
}

fn expectSubset(subset: []const []const u8, superset: []const []const u8) !void {
    for (subset) |name| {
        try std.testing.expect(contains(superset, name));
    }
}

test "managed and stale-allowed commands are forwarded" {
    try expectSubset(&managed, &forwarded);
    try expectSubset(&stale_allowed, &forwarded);
    try expectSubset(&node_creating, &managed);
}

test "command lists contain no duplicate names" {
    const lists = .{ &forwarded, &runtime_only, &managed, &stale_allowed, &node_creating };
    inline for (lists) |list| {
        const items: []const []const u8 = list;
        for (items, 0..) |name, index| {
            for (items[index + 1 ..]) |other| {
                try std.testing.expect(!std.mem.eql(u8, name, other));
            }
        }
    }
}

test "forwarded and runtime-only names are disjoint" {
    for (forwarded) |name| {
        try std.testing.expect(!contains(&runtime_only, name));
    }
}
