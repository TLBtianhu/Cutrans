//! An established environment is identified by the Runtime incarnation, not paths.
const std = @import("std");
const abi = @import("abi.zig");
const workspace = @import("workspace.zig");

pub const Session = extern struct {
    struct_size: u32 = @sizeOf(Session),
    version: u32 = 1,
    epoch_hi: u64,
    epoch_lo: u64,

    pub fn validate(self: *const Session) !void {
        if (self.struct_size != @sizeOf(Session) or self.version != 1) return error.InvalidEnvironmentSession;
        if (self.epoch_hi == 0 and self.epoch_lo == 0) return error.EnvironmentNotEstablished;
    }

    pub fn eql(a: Session, b: Session) bool {
        return a.epoch_hi == b.epoch_hi and a.epoch_lo == b.epoch_lo;
    }
};

/// Host attachment and Shell selection have already succeeded before this call.
/// The existing coherent Runtime snapshot supplies the incarnation identity.
pub fn establish(api: *const abi.ShellApi) !Session {
    if (!api.isCurrent() or api.context == null) return error.InvalidShellApi;
    var authority: workspace.Api = undefined;
    if (api.workspace_api(api.context, &authority) != abi.Status.ok) return error.EnvironmentUnavailable;
    if (authority.struct_size < @sizeOf(workspace.Api) or authority.api_version != workspace.version or authority.context == null) return error.InvalidWorkspaceApi;
    var metadata: workspace.Snapshot = undefined;
    var required: usize = 0;
    const status = authority.snapshot(authority.context, null, &metadata, null, 0, &required);
    if (status != abi.Status.buffer_too_small) return error.EnvironmentNotEstablished;
    if (metadata.struct_size < @sizeOf(workspace.Snapshot) or metadata.api_version != workspace.version or
        metadata.reserved != 0 or metadata.text_len != required or metadata.stamp.revision == 0) return error.InvalidEnvironmentSnapshot;
    const result = Session{ .epoch_hi = metadata.stamp.epoch_hi, .epoch_lo = metadata.stamp.epoch_lo };
    try result.validate();
    return result;
}

const Mock = struct {
    stamp: workspace.Stamp,

    fn snapshot(pointer: ?*anyopaque, _: ?*const workspace.Stamp, out: ?*workspace.Snapshot, _: ?[*]u8, _: usize, length: ?*usize) callconv(.c) i32 {
        const self: *Mock = @ptrCast(@alignCast(pointer.?));
        out.?.* = .{ .stamp = self.stamp, .fingerprint = 1, .node_id_high_water = 1, .flags = 0, .text_len = 1 };
        length.?.* = 1;
        return abi.Status.buffer_too_small;
    }

    fn workspaceApi(pointer: ?*anyopaque, out: ?*workspace.Api) callconv(.c) i32 {
        out.?.* = .{ .context = pointer, .snapshot = snapshot, .submit = undefined };
        return abi.Status.ok;
    }

    fn shellApi(self: *Mock) abi.ShellApi {
        var result: abi.ShellApi = undefined;
        result.struct_size = @sizeOf(abi.ShellApi);
        result.abi_version = abi.version;
        result.context = self;
        result.workspace_api = workspaceApi;
        return result;
    }
};

test "an established session uses the Runtime epoch and contains no paths" {
    var mock = Mock{ .stamp = .{ .epoch_hi = 11, .epoch_lo = 22, .revision = 1 } };
    const api = mock.shellApi();
    const session = try establish(&api);
    try std.testing.expectEqual(@as(u64, 11), session.epoch_hi);
    try std.testing.expectEqual(@as(u64, 22), session.epoch_lo);
    try session.validate();
    try std.testing.expect(session.eql(.{ .epoch_hi = 11, .epoch_lo = 22 }));
    mock.stamp.epoch_hi = 0;
    mock.stamp.epoch_lo = 0;
    try std.testing.expectError(error.EnvironmentNotEstablished, establish(&api));
}

test "old Shell and Workspace APIs cannot establish an environment" {
    var mock = Mock{ .stamp = .{ .epoch_hi = 1, .epoch_lo = 2, .revision = 1 } };
    var api = mock.shellApi();
    api.abi_version -= 1;
    try std.testing.expectError(error.InvalidShellApi, establish(&api));
    var session: Session = .{ .epoch_hi = 1, .epoch_lo = 2 };
    session.struct_size -= 1;
    try std.testing.expectError(error.InvalidEnvironmentSession, session.validate());
}
