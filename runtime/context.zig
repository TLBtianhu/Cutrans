//! context.zig — RuntimeContext:一个 VM 会话拥有的状态与销毁顺序
//!
//! Context 必须原地初始化,不能把包含自指针的实例按值搬来搬去。
//! surfaces/session/command/tasks/paths/mounts/devices/clock/playback/assets/config/status 都挂在同一上下文上。

const std = @import("std");
const surfaces = @import("surfaces.zig");
const session = @import("session.zig");
const command = @import("command.zig");
const tasks = @import("tasks.zig");
const paths = @import("paths.zig");
const config = @import("config.zig");
const status = @import("status.zig");
const console = @import("console.zig");
const documents = @import("documents.zig");
const history = @import("history.zig");
const export_job = @import("export_job.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io = null,
    surfaces: surfaces.Registry,
    session: session.State,
    command: command.Registry,
    tasks: tasks.Registry,
    paths: paths.Paths,
    mounts: @import("vne").mounts.Table,
    external_sources: @import("external_sources.zig").Catalog,
    library: @import("resource_library.zig").Catalog,
    library_view: @import("vne").library.View,
    devices: @import("vne").devices.Table,
    clock: @import("vne").clock.Clock,
    playback: @import("playback.zig").Playback,
    playback_view: @import("vne").playback.View,
    assets: @import("assets.zig").Workspace,
    asset_view: @import("vne").assets.View,
    history: history.History,
    config: config.Config,
    status: status.Status,
    console: console.State,
    document: documents.Document,
    /// Volatile publication revision; the Runtime incarnation scopes it.
    document_revision: u64 = 1,
    exports: [8]export_job.Job = undefined,
    export_count: usize = 0,
    active_export: ?export_job.Job = null,
    active_cancel: std.atomic.Value(bool) = .init(false),
    pending_finalize: ?@import("job_ledger.zig").Record = null,
    runtime_origin: @import("vne").workspace.Stamp = .{},
    editor_state: ?*anyopaque = null,
    library_state: ?*anyopaque = null,

    pub fn init(self: *Context, allocator: std.mem.Allocator) void {
        self.* = .{
            .allocator = allocator,
            .surfaces = undefined,
            .session = undefined,
            .command = undefined,
            .tasks = undefined,
            .paths = .{},
            .mounts = .{},
            .external_sources = .{},
            .library = .{},
            .library_view = .{},
            .devices = .{},
            .clock = .{ .system = null },
            .playback = .{},
            .playback_view = .{},
            .assets = .{},
            .asset_view = .{},
            .history = undefined,
            .config = .{},
            .status = .{},
            .console = .{},
            .document = documents.Document.initDefault(),
            .document_revision = 1,
        };
        self.surfaces.init(self);
        self.session.init(allocator, &self.surfaces);
        self.command.init(allocator, self);
        self.tasks.init();
        self.history.init();
    }

    pub fn deinit(self: *Context) void {
        self.session.deinit();
        self.surfaces.deinit();
        self.command.deinit();
        self.tasks.reset();
        self.history.reset();
        self.playback.stop(self.allocator);
        self.playback_view = .{};
        self.asset_view.deinit(self.allocator);
        self.assets.deinit();
        self.devices.reset();
        self.library_view.deinit(self.allocator);
        self.library.deinit(self.allocator);
        self.external_sources.deinit(self.allocator);
        self.mounts.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.status.clear();
        self.console.reset();
        self.document = documents.Document.initDefault();
        self.document_revision = 1;
        self.export_count = 0;
        self.active_export = null;
        self.active_cancel = .init(false);
        self.pending_finalize = null;
        self.runtime_origin = .{};
        self.clock = .{ .system = null };
        self.io = null;
        self.config = .{};
    }
};
