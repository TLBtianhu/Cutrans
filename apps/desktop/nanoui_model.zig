const std = @import("std");
const nanoui = @import("nanoui");

const abi = @import("vne").abi;
const vm_client = @import("vm_client");
const input_bridge = @import("nanoui_input");
const editor_view = @import("editor");
const library_view = @import("nanoui_library");
const console_view = @import("nanoui_console");

pub const Page = enum { home, editor, library, files, console, jobs };

fn requiredPath(value: abi.ByteSlice) ![]const u8 {
    if (value.len == 0 or value.ptr == null) return error.InvalidPath;
    const path = value.ptr.?[0..value.len];
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    return path;
}

pub const State = struct {
    allocator: std.mem.Allocator,
    io_state: std.Io.Threaded,
    ctx: vm_client.Context,
    api: abi.ShellApi,
    session: @import("vne").environment_session.Session,
    window: ?*nanoui.Window = null,
    page: Page,
    editor: editor_view.State,
    library: library_view.State,
    files: @import("local_files").State,
    console: console_view.State,
    input: input_bridge.Bridge,
    last_presented_offer: u64 = 0,
    last_frame_log_generation: u64 = 0,
    last_frame_log_t: ?i64 = null,
    exit: @import("exit_model.zig").State,

    pub fn init(process: std.process.Init, config: *const abi.ShellConfig, api: *const abi.ShellApi, hooks: *@import("shell").client.ExitHooks) !*State {
        if (config.struct_size < @sizeOf(abi.ShellConfig) or config.abi_version != abi.version or config.reserved != 0) return error.InvalidShellConfig;
        if (config.playback_frames < 0 or config.playback_frames > 600 or config.asset_workspace > 3) return error.InvalidPlaybackConfig;
        const allocator = process.gpa;
        const self = try allocator.create(State);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io_state = undefined,
            .ctx = undefined,
            .api = api.*,
            .session = undefined,
            .page = if (config.asset_workspace == 2) .files else if (config.open_path.len != 0) .editor else .home,
            .editor = undefined,
            .library = undefined,
            .files = undefined,
            .console = undefined,
            .input = .{ .api = api.* },
            .exit = .{ .hooks = hooks },
        };
        self.io_state = std.Io.Threaded.init(allocator, .{});
        errdefer self.io_state.deinit();
        self.ctx.init(allocator);
        errdefer self.ctx.deinit();
        self.ctx.io = self.io_state.io();
        self.ctx.paths = try vm_client.Paths.fromDirsPhysical(allocator, self.ctx.io.?, try abi.modeFromInt(config.mode), try requiredPath(config.resource_dir), try requiredPath(config.data_dir));
        try vm_client.init(api);
        errdefer vm_client.deinit();
        try vm_client.register(&self.ctx);
        vm_client.recoverPendingMarker(&self.ctx);
        self.session = try @import("vne").environment_session.establish(api);
        self.editor = editor_view.State.init(&self.ctx);
        errdefer self.editor.deinit();
        self.library = try library_view.State.init(allocator, api, self.ctx.io);
        errdefer self.library.deinit();
        self.files = try @import("local_files").State.init(allocator, api, self.session);
        errdefer self.files.deinit();
        self.files.on_register = .{ .context = self, .run = registerLocal };
        self.console = console_view.State.init(&self.ctx);
        self.library.on_insert = .{ .context = self, .run = insertLibrary };
        if (config.asset_workspace == 2) {
            if (config.open_path.len == 0) return error.MissingLocalBrowseRoot;
            try self.files.open(try requiredPath(config.open_path), 0);
        }
        self.console.refreshJobs() catch {};
        return self;
    }

    pub fn deinit(self: *State) void {
        const allocator = self.allocator;
        self.console.deinit();
        self.files.deinit();
        self.library.deinit();
        self.editor.deinit();
        vm_client.deinit();
        self.ctx.deinit();
        self.io_state.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    fn registerLocal(pointer: ?*anyopaque, path: []const u8, folder_label: ?[]const u8) !u64 {
        const self: *State = @ptrCast(@alignCast(pointer.?));
        const id = try self.library.importExternal(path);
        if (folder_label) |label| {
            var folder: ?u64 = null;
            for (self.library.catalog.items[0..self.library.catalog.count]) |item| {
                if (item.node_kind == .folder and item.parent_id == 0 and std.mem.eql(u8, item.label, label)) {
                    folder = item.id;
                    break;
                }
            }
            const parent = folder orelse try self.library.createFolder(0, label);
            try self.library.moveLibrary(id, parent);
        }
        self.page = .library;
        return id;
    }

    pub fn importDropped(self: *State, paths: []const []const u8) void {
        if (self.exit.active() or paths.len == 0) return;
        self.page = .library;
        for (paths, 0..) |path, index| {
            _ = self.library.importExternal(path) catch |err| {
                self.library.fail(if (index == 0) "外部素材登记失败" else "部分外部素材登记失败", err);
                return;
            };
        }
        self.library.setStatus("已从本机登记 {d} 个素材；引用/拥有状态见资源库", .{paths.len});
    }

    fn insertLibrary(pointer: ?*anyopaque, handle: u64) !void {
        const self: *State = @ptrCast(@alignCast(pointer.?));
        try self.editor.insertHandle(handle);
        self.page = .editor;
    }

    pub fn showPage(self: *State, page: Page) void {
        self.page = page;
        switch (page) {
            .editor => std.debug.print("app.open editor\n", .{}),
            .library => std.debug.print("app.open library\n", .{}),
            .files => std.debug.print("app.open local-files\n", .{}),
            .console => std.debug.print("app.open cli\n", .{}),
            .jobs => std.debug.print("app.open jobs\n", .{}),
            .home => {},
        }
        if (page == .jobs) self.console.refreshJobs() catch {};
    }

    pub fn beginExit(self: *State) void {
        self.exit.begin(&self.library, &self.console) catch |err| self.exit.noteError(err);
    }

    pub fn requestClose(self: *State) void {
        switch (closeAction(self.exit.phase)) {
            .close => if (self.window) |window| window.close(),
            .block => {},
            .begin_exit => self.beginExit(),
        }
    }

    /// Closing the window is a Shell detach, not a stop. While an explicit
    /// environment exit is in progress, leave the window open so the exit can
    /// finish or be resumed. A normal close starts the same safe exit; only a
    /// finished or failed exit may actually destroy the window.
    pub const CloseAction = enum { close, block, begin_exit };

    pub fn closeAction(phase: @import("exit_model.zig").Phase) CloseAction {
        return switch (phase) {
            .inactive => .begin_exit,
            .failed, .stopped => .close,
            else => .block,
        };
    }

    pub fn shouldClose(pointer: *anyopaque, _: *nanoui.Window) bool {
        const self: *State = @ptrCast(@alignCast(pointer));
        switch (closeAction(self.exit.phase)) {
            .close => return true,
            .block => return false,
            .begin_exit => {
                self.beginExit();
                return false;
            },
        }
    }

    fn terminal(state: []const u8) bool {
        return !std.mem.eql(u8, state, "queued") and !std.mem.eql(u8, state, "running");
    }

    fn exportPending(self: *State) bool {
        const id = self.editor.last_task_id orelse return false;
        if (self.console.jobs) |jobs| {
            for (jobs.value.items) |job| {
                if (job.id == id and terminal(job.state)) {
                    self.editor.last_task_id = null;
                    return false;
                }
            }
        }
        return true;
    }

    pub fn beforeFrame(self: *State, c: *nanoui.ui.Context) void {
        if (self.exit.active()) {
            self.input.edits_allowed = false;
            self.exit.tick(c, &self.console);
            return;
        }
        self.input.edits_allowed = vm_client.mirrorsFresh();
        self.input.flush(c) catch |err| self.ctx.status.set(@errorName(err));
        vm_client.pump(&self.ctx) catch |err| self.ctx.status.set(@errorName(err));
        if (self.page == .library) {
            self.library.sync() catch |err| self.library.fail("目录投影同步失败", err);
            if (self.library.needsFrame()) c.frameIn(0.05);
        }
        if (self.console.hasActiveWork() or self.exportPending() or self.page == .jobs) {
            self.console.refreshJobs() catch {};
            c.frameIn(0.1);
        }
        if (self.ctx.playback_view.active) c.frameIn(0.016);
    }

    pub fn confirmPresent(self: *State) void {
        if (self.exit.active() or !vm_client.mirrorsFresh()) return;
        const sink = &self.ctx.devices.frame_sink;
        if (sink.offer_count == self.last_presented_offer or sink.last_generation == 0) return;
        const report = abi.FrameReport{
            .struct_size = @sizeOf(abi.FrameReport),
            .abi_version = abi.version,
            .content_id = sink.last_content_id,
            .generation = sink.last_generation,
            .t = sink.last_t,
            .kind = @backingInt(@import("vne").frame.ReportKind.submitted),
        };
        vm_client.frameReport(&report) catch |err| {
            self.ctx.status.set(@errorName(err));
            return;
        };
        self.last_presented_offer = sink.offer_count;
        if (report.generation != self.last_frame_log_generation or self.last_frame_log_t == null or report.t != self.last_frame_log_t.?) {
            std.debug.print("CUTRANS_SHELL_FRAME_OK generation={d} content={d} t={d}\n", .{ report.generation, report.content_id, report.t });
            self.last_frame_log_generation = report.generation;
            self.last_frame_log_t = report.t;
        }
    }

    pub fn onPresent(pointer: *anyopaque, _: *nanoui.Window) void {
        const self: *State = @ptrCast(@alignCast(pointer));
        self.confirmPresent();
    }

    pub fn view(self: *State, c: *nanoui.ui.Context) void {
        self.beforeFrame(c);
        @import("nanoui_view.zig").view(self, c);
    }
};

test "closing starts safe exit unless it already finished or failed" {
    try std.testing.expectEqual(State.CloseAction.begin_exit, State.closeAction(.inactive));
    inline for (.{ .confirm, .waiting, .cancelling, .ready, .stopping }) |phase| {
        try std.testing.expectEqual(State.CloseAction.block, State.closeAction(phase));
    }
    try std.testing.expectEqual(State.CloseAction.close, State.closeAction(.failed));
    try std.testing.expectEqual(State.CloseAction.close, State.closeAction(.stopped));
}
