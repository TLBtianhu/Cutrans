const std = @import("std");
const nanoui = @import("nanoui");
const abi = @import("vne").abi;
const mirror = @import("shell").mirror;

pub const Insert = struct {
    context: ?*anyopaque,
    run: *const fn (?*anyopaque, u64) anyerror!void,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    api: abi.ShellApi,
    catalog: @import("vne").library.View = .{},
    assets: @import("vne").assets.View = .{},
    selected_folder: u64 = 0,
    selected_library: u64 = 0,
    selected_handle: u64 = 0,
    preview: ?mirror.Preview = null,
    work: ?@import("work_model.zig").Model = null,
    menu_open: bool = false,
    menu_target: u64 = 0,
    menu_anchor: ?nanoui.ui.Rect = null,
    rename_target: u64 = 0,
    rename_buffer: nanoui.ui.TextBuffer = .{},
    new_folder_buffer: nanoui.ui.TextBuffer = .{},
    on_insert: ?Insert = null,
    status_storage: [320]u8 = @splat(0),
    status_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, api: *const abi.ShellApi, io: ?std.Io) !State {
        // Validate the readable ABI prefix before copying an enlarged table.
        if (!api.isCurrent()) return error.InvalidShellApi;
        if (api.context == null) return error.MissingRuntimeHandle;
        var self: State = .{ .allocator = allocator, .api = api.* };
        self.work = @import("work_model.zig").Model.init(allocator, api, io);
        errdefer self.deinit();
        try self.sync();
        self.setStatus("资源库已连接；选择素材即可预览", .{});
        return self;
    }

    pub fn deinit(self: *State) void {
        self.clearPreview();
        if (self.work) |*work| work.deinit();
        self.catalog.deinit(self.allocator);
        self.assets.deinit(self.allocator);
        self.rename_buffer.deinit();
        self.new_folder_buffer.deinit();
        self.api = undefined;
    }

    pub fn shouldClose(pointer: *anyopaque, _: *nanoui.Window) bool {
        const self: *State = @ptrCast(@alignCast(pointer));
        if (self.work) |*work| return work.beforeClose();
        return true;
    }

    pub fn setStatus(self: *State, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.status_storage, fmt, args) catch {
            const fallback = "状态信息过长";
            @memcpy(self.status_storage[0..fallback.len], fallback);
            self.status_len = fallback.len;
            return;
        };
        self.status_len = text.len;
    }

    pub fn status(self: *const State) []const u8 {
        return self.status_storage[0..self.status_len];
    }

    pub fn fail(self: *State, message: []const u8, err: anyerror) void {
        self.setStatus("{s}：{s}", .{ message, @errorName(err) });
    }

    pub fn clearPreview(self: *State) void {
        if (self.preview) |*preview| preview.deinit(self.allocator);
        self.preview = null;
        self.selected_handle = 0;
    }

    pub fn sync(self: *State) !void {
        try mirror.syncLibrary(self.allocator, &self.api, &self.catalog);
        try mirror.syncAssets(self.allocator, &self.api, &self.assets);
        if (self.work) |*work| try work.pump();
    }

    fn command(self: *State, name: []const u8, arg: []const u8) !void {
        if (try mirror.command(&self.api, name, arg) != abi.Status.ok) return error.CommandFailed;
    }

    pub fn selectFolder(self: *State, id: u64) !void {
        if (id != 0) {
            const folder = self.catalog.find(id) orelse return error.InvalidLibraryFolder;
            if (folder.node_kind != .folder) return error.InvalidLibraryFolder;
        }
        if (self.work) |*work| try work.close();
        self.selected_folder = id;
        self.selected_library = 0;
        self.rename_target = 0;
        self.clearPreview();
    }

    pub fn selectLibrary(self: *State, id: u64) !void {
        const item = self.catalog.findResource(id) orelse return error.InvalidLibraryResource;
        if (self.work) |*work| {
            if (item.kind.? == .owned) {
                work.open(id) catch |err| switch (err) {
                    error.UnsupportedWorkText, error.NotWorkResource => try work.close(),
                    else => return err,
                };
                if (work.editor != null) {
                    self.clearPreview();
                    self.selected_library = id;
                    self.selected_folder = item.parent_id;
                    self.setStatus("工作正文 · 自动保存草稿，Ctrl+S 提交", .{});
                    return;
                }
            }
            if (work.editor != null) try work.close();
        }
        const selected = try mirror.ensureLibrary(&self.api, self.allocator, &self.assets, id, item.content_hash);
        if (self.selected_handle == selected and self.preview != null) {
            self.selected_library = id;
            self.selected_folder = item.parent_id;
            return;
        }
        const candidate = try mirror.previewPng(self.allocator, &self.api, selected, item.content_hash);
        self.clearPreview();
        self.preview = candidate;
        self.selected_library = id;
        self.selected_folder = item.parent_id;
        self.selected_handle = selected;
        self.setStatus("PNG {d}×{d} · 完整预览", .{ self.preview.?.info.width, self.preview.?.info.height });
        std.debug.print("CUTRANS_NANOUI_PREVIEW library={d} asset={d} width={d} height={d}\n", .{ id, selected, self.preview.?.info.width, self.preview.?.info.height });
    }

    pub fn createText(self: *State, label: []const u8) !u64 {
        const work = if (self.work) |*value| value else return error.WorkApiUnavailable;
        const id = try work.create(label);
        try self.sync();
        try self.selectLibrary(id);
        self.setStatus("已创建工作正文；输入会自动保存为草稿", .{});
        return id;
    }

    pub fn checkSelectedSource(self: *State) !void {
        if (self.selected_handle == 0 or self.assets.find(self.selected_handle) == null) return error.AssetSelectionRequired;
        var buffer: [32]u8 = undefined;
        try self.command("asset.check", try std.fmt.bufPrint(&buffer, "{d}", .{self.selected_handle}));
        try mirror.syncAssets(self.allocator, &self.api, &self.assets);
        const item = self.assets.find(self.selected_handle) orelse return error.AssetMirrorMissing;
        self.setStatus("{s}", .{mirror.sourceStatusText(item.source_state)});
    }

    pub fn importExternal(self: *State, path: []const u8) !u64 {
        const handle = try mirror.openExternal(&self.api, path);
        try self.sync();
        const asset = self.assets.find(handle) orelse return error.AssetMirrorMissing;
        if (asset.library_id == 0) return error.LibraryMirrorMissing;
        try self.selectLibrary(asset.library_id);
        return handle;
    }

    pub fn pickExternal(self: *State) !void {
        const selected = try nanoui.dialog.open(self.allocator, .{
            .title = "导入 PNG 到 VM 资源库",
            .button = "导入",
            .extensions = &.{"png"},
        });
        if (selected) |paths| {
            defer nanoui.dialog.freePaths(self.allocator, paths);
            if (paths.len == 0) return;
            _ = try self.importExternal(paths[0]);
        }
    }

    pub fn refreshLibrary(self: *State, id: u64) !void {
        const item = self.catalog.findResource(id) orelse return error.InvalidLibraryResource;
        if (item.kind != .reference) return error.NotExternalReference;
        var buffer: [32]u8 = undefined;
        try self.command("library.refresh", try std.fmt.bufPrint(&buffer, "{d}", .{id}));
        try self.sync();
        try self.selectLibrary(id);
        self.setStatus("已从原文件重新载入；文档继续使用原有版本", .{});
    }

    pub fn detachLibrary(self: *State, id: u64) !void {
        const item = self.catalog.findResource(id) orelse return error.InvalidLibraryResource;
        if (item.kind != .reference) return error.NotExternalReference;
        var buffer: [32]u8 = undefined;
        try self.command("library.detach", try std.fmt.bufPrint(&buffer, "{d}", .{id}));
        try self.sync();
        if (self.selected_library == id) try self.selectLibrary(id);
        self.setStatus("已保存为库内独立副本；文档引用保持不变", .{});
    }

    pub fn createFolder(self: *State, parent_id: u64, label: []const u8) !u64 {
        var buffer: [192]u8 = undefined;
        try self.command("library.folder.create", try std.fmt.bufPrint(&buffer, "{d} {s}", .{ parent_id, label }));
        try mirror.syncLibrary(self.allocator, &self.api, &self.catalog);
        var created: ?u64 = null;
        for (self.catalog.items[0..self.catalog.count]) |item| {
            if (item.node_kind == .folder and item.parent_id == parent_id and std.mem.eql(u8, item.label, label)) created = item.id;
        }
        self.setStatus("文件夹已创建", .{});
        return created orelse error.LibraryMirrorMissing;
    }

    pub fn moveLibrary(self: *State, id: u64, parent_id: u64) !void {
        const item = self.catalog.find(id) orelse return error.InvalidLibraryResource;
        const node_kind = item.node_kind;
        if (parent_id != 0) {
            const parent = self.catalog.find(parent_id) orelse return error.InvalidLibraryFolder;
            if (parent.node_kind != .folder) return error.InvalidLibraryFolder;
        }
        var buffer: [64]u8 = undefined;
        try self.command("library.move", try std.fmt.bufPrint(&buffer, "{d} {d}", .{ id, parent_id }));
        try mirror.syncLibrary(self.allocator, &self.api, &self.catalog);
        if (node_kind == .resource and self.selected_library == id) self.selected_folder = parent_id;
        self.setStatus("已移动；素材内容与文档引用保持不变", .{});
    }

    pub fn beginRename(self: *State, id: u64) !void {
        const item = self.catalog.find(id) orelse return error.InvalidLibraryResource;
        self.rename_target = id;
        self.rename_buffer.set(item.label);
        self.rename_buffer.focus();
        self.menu_open = false;
    }

    pub fn applyRename(self: *State) !void {
        if (self.rename_target == 0) return error.NothingToRename;
        var buffer: [192]u8 = undefined;
        try self.command("library.rename", try std.fmt.bufPrint(&buffer, "{d} {s}", .{ self.rename_target, self.rename_buffer.text() }));
        try mirror.syncLibrary(self.allocator, &self.api, &self.catalog);
        self.rename_target = 0;
        self.rename_buffer.clear();
        self.setStatus("名称已更新；素材内容与文档引用保持不变", .{});
    }
};

test "selecting a changed head keeps the prior successful preview when the replacement fails" {
    const Mock = struct {
        previews: usize = 0,
        last_handle: u64 = 0,
        ensures: usize = 0,

        fn preview(pointer: ?*anyopaque, handle: u64, _: ?*abi.AssetInfo) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            self.previews += 1;
            self.last_handle = handle;
            return abi.Status.failed;
        }

        fn ensure(pointer: ?*anyopaque, _: abi.ByteSlice, _: abi.ByteSlice, task: ?*u64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            self.ensures += 1;
            if (task) |out| out.* = 0;
            return abi.Status.accepted;
        }

        fn assets(_: ?*anyopaque, out: ?*abi.AssetListReport) callconv(.c) i32 {
            out.?.* = .{ .struct_size = @sizeOf(abi.AssetListReport), .abi_version = abi.version, .revision = 1, .count = 2, .entries = @splat(.{}) };
            out.?.entries[0] = .{ .handle = 11, .byte_length = 72, .leases = 1, .source_kind = 3, .library_kind = 1, .library_id = 7, .content_hash = @splat(0x11) };
            out.?.entries[1] = .{ .handle = 22, .byte_length = 72, .leases = 1, .source_kind = 3, .library_kind = 1, .library_id = 7, .content_hash = @splat(0x22) };
            return abi.Status.ok;
        }
    };
    var mock: Mock = .{};
    var api: abi.ShellApi = undefined;
    api.struct_size = @sizeOf(abi.ShellApi);
    api.abi_version = abi.version;
    api.context = &mock;
    api.asset_preview = Mock.preview;
    api.command_result = Mock.ensure;
    api.asset_list = Mock.assets;
    var state = State{ .allocator = std.testing.allocator, .api = api, .selected_library = 7, .selected_handle = 11, .selected_folder = 0 };
    defer state.deinit();
    state.catalog.items[0] = .{ .id = 7, .label = try std.testing.allocator.dupe(u8, "head.png"), .node_kind = .resource, .kind = .reference, .provenance = .external, .content_hash = @splat(0x22) };
    state.catalog.count = 1;
    for ([_]u64{ 11, 22 }, 0..) |handle, index| {
        state.assets.items[index] = .{ .handle = handle, .byte_length = 72, .leases = 1, .source_kind = 3, .library_kind = 1, .library_id = 7, .content_hash = if (index == 0) @splat(0x11) else @splat(0x22), .source = try std.testing.allocator.dupe(u8, "library://7") };
        state.assets.count += 1;
    }
    state.assets.revision = 1;
    state.preview = .{ .info = .{ .struct_size = @sizeOf(abi.AssetInfo), .abi_version = abi.version, .handle = 11, .byte_length = 3, .content_hash = @splat(0x11), .width = 1, .height = 1, .media_kind = 1, .coverage = 1 }, .bytes = try std.testing.allocator.dupe(u8, "old") };
    const old_bytes = state.preview.?.bytes.ptr;
    try std.testing.expectError(error.AssetPreviewFailed, state.selectLibrary(7));
    try std.testing.expectEqual(@as(u64, 22), mock.last_handle);
    try std.testing.expectEqual(@as(u64, 11), state.selected_handle);
    try std.testing.expectEqual(old_bytes, state.preview.?.bytes.ptr);
    try std.testing.expectEqualStrings("old", state.preview.?.bytes);
    state.catalog.items[0].content_hash = @splat(0x11);
    try state.selectLibrary(7);
    try std.testing.expectEqual(@as(usize, 1), mock.previews);
    try std.testing.expectEqual(@as(usize, 2), mock.ensures);
    try std.testing.expectEqual(@as(u32, 1), state.assets.items[0].leases);
    try std.testing.expectEqual(@as(u32, 1), state.assets.items[1].leases);
}
