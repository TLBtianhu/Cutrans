//! Read-only local browsing. Registration remains an explicit VM action.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const abi = @import("vne").abi;
const resource = @import("vne").resource_api;
const palette = @import("palette");

pub const Register = struct {
    context: ?*anyopaque,
    run: *const fn (?*anyopaque, []const u8, ?[]const u8) anyerror!u64,
};

const Kind = enum { file, directory };
const Entry = struct { name: []u8, kind: Kind, size: u64 };
const Page = struct {
    path: []u8,
    cursor: u64,
    next_cursor: ?u64,
    total: usize,
    entries: []Entry,

    fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| allocator.free(entry.name);
        allocator.free(self.entries);
        allocator.free(self.path);
        self.* = undefined;
    }
};
const WireEntry = struct { name: []const u8, kind: []const u8, size: u64 };
const Manifest = struct {
    format: []const u8,
    path: []const u8,
    cursor: u64,
    next_cursor: ?u64,
    total: usize,
    entries: []WireEntry,
};
const PreviewKind = enum { text, image, unsupported };
const Preview = struct {
    path: []u8,
    bytes: []u8,
    kind: PreviewKind,

    fn deinit(self: *Preview, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    session: @import("vne").environment_session.Session,
    authority: ?resource.Api = null,
    path_input: ui.TextBuffer = .{},
    current: ?Page = null,
    preview: ?Preview = null,
    selected: ?usize = null,
    on_register: ?Register = null,
    status_storage: [320]u8 = @splat(0),
    status_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, api: *const abi.ShellApi, session: @import("vne").environment_session.Session) !State {
        try session.validate();
        var self = State{ .allocator = allocator, .session = session };
        var authority: resource.Api = undefined;
        if (api.resource_api(api.context, &authority) == abi.Status.ok and authority.isCurrent()) self.authority = authority;
        return self;
    }

    pub fn deinit(self: *State) void {
        if (self.current) |*page| page.deinit(self.allocator);
        if (self.preview) |*preview| preview.deinit(self.allocator);
        self.path_input.deinit();
        self.* = undefined;
    }

    fn setStatus(self: *State, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.status_storage, fmt, args) catch {
            const fallback = "本机文件状态信息过长";
            @memcpy(self.status_storage[0..fallback.len], fallback);
            self.status_len = fallback.len;
            return;
        };
        self.status_len = text.len;
    }
    pub fn status(self: *const State) []const u8 {
        return self.status_storage[0..self.status_len];
    }

    fn validName(name: []const u8) bool {
        return name.len != 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
            std.mem.indexOfAny(u8, name, "/\\\x00") == null;
    }

    fn readBrowse(self: *State, path: []const u8, cursor: u64) ![]u8 {
        const authority = self.authority orelse return error.SourceApiUnavailable;
        var required: usize = 0;
        const query = authority.source_browse(authority.context, .{ .ptr = path.ptr, .len = path.len }, cursor, 128, null, 0, &required);
        if (query != abi.Status.buffer_too_small or required == 0 or required > 1024 * 1024) return error.SourceBrowseFailed;
        const bytes = try self.allocator.alloc(u8, required);
        errdefer self.allocator.free(bytes);
        const read_status = authority.source_browse(authority.context, .{ .ptr = path.ptr, .len = path.len }, cursor, 128, bytes.ptr, bytes.len, &required);
        if (read_status != abi.Status.ok) return error.SourceBrowseFailed;
        return bytes;
    }

    fn parsePage(self: *State, bytes: []const u8) !Page {
        const parsed = try std.json.parseFromSlice(Manifest, self.allocator, bytes, .{ .ignore_unknown_fields = false, .allocate = .alloc_always });
        defer parsed.deinit();
        const value = parsed.value;
        if (!std.mem.eql(u8, value.format, "cutrans-local-directory/1") or !std.fs.path.isAbsolute(value.path) or
            value.path.len > 4096 or value.cursor > value.total or value.total > 4096 or value.entries.len > 128 or
            value.cursor + value.entries.len > value.total or
            (if (value.next_cursor) |next| next != value.cursor + value.entries.len or next > value.total else value.cursor + value.entries.len != value.total)) return error.InvalidSourcePage;
        const path = try self.allocator.dupe(u8, value.path);
        errdefer self.allocator.free(path);
        const entries = try self.allocator.alloc(Entry, value.entries.len);
        var count: usize = 0;
        errdefer {
            for (entries[0..count]) |entry| self.allocator.free(entry.name);
            self.allocator.free(entries);
        }
        for (value.entries) |entry| {
            if (!validName(entry.name)) return error.InvalidSourceEntry;
            const kind = std.meta.stringToEnum(Kind, entry.kind) orelse return error.InvalidSourceEntry;
            entries[count] = .{ .name = try self.allocator.dupe(u8, entry.name), .kind = kind, .size = entry.size };
            count += 1;
        }
        return .{ .path = path, .cursor = value.cursor, .next_cursor = value.next_cursor, .total = value.total, .entries = entries };
    }

    pub fn open(self: *State, path: []const u8, cursor: u64) !void {
        if (!std.fs.path.isAbsolute(path) or path.len == 0) return error.InvalidSourcePath;
        const bytes = try self.readBrowse(path, cursor);
        defer self.allocator.free(bytes);
        var page = try self.parsePage(bytes);
        errdefer page.deinit(self.allocator);
        if (self.current) |*old| old.deinit(self.allocator);
        self.current = page;
        self.selected = null;
        if (self.preview) |*preview| preview.deinit(self.allocator);
        self.preview = null;
        self.path_input.set(page.path);
        self.setStatus("只读浏览 · {d} 项 · 尚未登记为 VM 资源", .{page.total});
    }

    pub fn refresh(self: *State) !void {
        const page = if (self.current) |*value| value else return error.NoLocalDirectory;
        try self.open(page.path, page.cursor);
    }

    pub fn nextPage(self: *State) !void {
        const page = if (self.current) |*value| value else return error.NoLocalDirectory;
        try self.open(page.path, page.next_cursor orelse return error.NoNextSourcePage);
    }

    pub fn parent(self: *State) !void {
        const page = if (self.current) |*value| value else return error.NoLocalDirectory;
        const parent_path = std.fs.path.dirname(page.path) orelse return error.NoLocalParent;
        if (std.mem.eql(u8, parent_path, page.path)) return;
        try self.open(parent_path, 0);
    }

    pub fn pick(self: *State) !void {
        const selected = try @import("ports").file_dialog.pickDirectory(self.allocator, null);
        if (selected) |path| {
            defer self.allocator.free(path);
            try self.open(path, 0);
        }
    }

    fn selectedPath(self: *State) ![]u8 {
        const page = if (self.current) |*value| value else return error.NoLocalDirectory;
        const index = self.selected orelse return error.NoLocalSelection;
        if (index >= page.entries.len) return error.NoLocalSelection;
        return std.fs.path.join(self.allocator, &.{ page.path, page.entries[index].name });
    }

    fn readFile(self: *State, path: []const u8) !Preview {
        const authority = self.authority orelse return error.SourceApiUnavailable;
        var required: usize = 0;
        const query = authority.source_read(authority.context, .{ .ptr = path.ptr, .len = path.len }, null, 0, &required);
        if (query != abi.Status.buffer_too_small or required > 16 * 1024 * 1024) return error.SourceReadFailed;
        const bytes = try self.allocator.alloc(u8, required);
        errdefer self.allocator.free(bytes);
        const read_status = authority.source_read(authority.context, .{ .ptr = path.ptr, .len = path.len }, bytes.ptr, bytes.len, &required);
        if (read_status != abi.Status.ok) return error.SourceReadFailed;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const is_text = bytes.len <= 1024 * 1024 and std.unicode.utf8ValidateSlice(bytes) and std.mem.indexOfScalar(u8, bytes, 0) == null;
        const is_png = std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n");
        return .{ .path = owned_path, .bytes = bytes, .kind = if (is_text) .text else if (is_png) .image else .unsupported };
    }

    pub fn select(self: *State, index: usize) !void {
        const page = if (self.current) |*value| value else return error.NoLocalDirectory;
        if (index >= page.entries.len) return error.InvalidLocalSelection;
        if (page.entries[index].kind == .directory) {
            self.selected = index;
            self.setStatus("目录 · 使用打开进入，不会递归登记", .{});
            return;
        }
        const path = try std.fs.path.join(self.allocator, &.{ page.path, page.entries[index].name });
        defer self.allocator.free(path);
        var candidate = try self.readFile(path);
        errdefer candidate.deinit(self.allocator);
        if (self.preview) |*old| old.deinit(self.allocator);
        self.preview = candidate;
        self.selected = index;
        self.setStatus("临时读取 · 未登记 · 不是固定内容版本", .{});
    }

    pub fn openSelected(self: *State) !void {
        const page = if (self.current) |*value| value else return error.NoLocalDirectory;
        const index = self.selected orelse return error.NoLocalSelection;
        if (index >= page.entries.len) return error.NoLocalSelection;
        if (page.entries[index].kind == .file) return self.select(index);
        const path = try self.selectedPath();
        defer self.allocator.free(path);
        try self.open(path, 0);
    }

    fn folderLabel(path: []const u8) []const u8 {
        const name = std.fs.path.basename(path);
        return if (name.len == 0) "本机目录" else name;
    }

    pub fn registerSelected(self: *State, into_folder: bool) !void {
        const page = if (self.current) |*value| value else return error.NoLocalDirectory;
        const index = self.selected orelse return error.NoLocalSelection;
        if (index >= page.entries.len or page.entries[index].kind != .file) return error.OnlyFileRegistration;
        const path = try self.selectedPath();
        defer self.allocator.free(path);
        const callback = self.on_register orelse return error.RegistrationUnavailable;
        _ = try callback.run(callback.context, path, if (into_folder) folderLabel(page.path) else null);
        if (into_folder) {
            self.setStatus("已收录到同名文件夹；成员与来源保持显式关系", .{});
        } else {
            self.setStatus("已显式登记；资源库与消费结果分别对账", .{});
        }
    }

    pub fn view(self: *State, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(16), .gap = 10 });
        defer ui.end(c);
        ui.text(c, "本机文件", .{ .size = 22, .weight = .bold });
        ui.label(c, "只读浏览当前一层；只有显式收录才建立 VM 资源。目录、预览和固定版本互不冒充。");
        ui.row(c, .{ .width = .fill, .gap = 8 });
        {
            defer ui.end(c);
            _ = ui.textField(c, &self.path_input, .{ .placeholder = "输入绝对目录路径", .width = .fill });
            if (ui.button(c, "打开路径", .{}).clicked) self.open(self.path_input.text(), 0) catch |err| self.setStatus("打开失败：{s}", .{@errorName(err)});
            if (ui.button(c, "选择目录…", .{}).clicked) self.pick() catch |err| self.setStatus("目录选择失败：{s}", .{@errorName(err)});
        }
        ui.row(c, .{ .width = .fill, .gap = 8 });
        {
            defer ui.end(c);
            if (ui.button(c, "返回上级", .{ .disabled = self.current == null }).clicked) self.parent() catch |err| self.setStatus("返回失败：{s}", .{@errorName(err)});
            if (ui.button(c, "刷新", .{ .disabled = self.current == null }).clicked) self.refresh() catch |err| self.setStatus("刷新失败：{s}", .{@errorName(err)});
            if (ui.button(c, "下一页", .{ .disabled = self.current == null or self.current.?.next_cursor == null }).clicked) self.nextPage() catch |err| self.setStatus("翻页失败：{s}", .{@errorName(err)});
            if (ui.button(c, "打开选中项", .{ .disabled = self.selected == null }).clicked) self.openSelected() catch |err| self.setStatus("打开失败：{s}", .{@errorName(err)});
            if (ui.button(c, "收录到资源库", .{ .variant = .primary, .disabled = self.selected == null }).clicked) self.registerSelected(false) catch |err| self.setStatus("登记失败：{s}", .{@errorName(err)});
            if (ui.button(c, "收录到同名文件夹", .{ .disabled = self.selected == null }).clicked) self.registerSelected(true) catch |err| self.setStatus("收纳失败：{s}", .{@errorName(err)});
        }
        if (self.current) |*page| {
            ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "{s} · 第 {d} 项起 · 共 {d} 项", .{ page.path, page.cursor + 1, page.total });
            ui.scroll(c, .{ .width = .fill, .height = .{ .px = 230 }, .gap = 2 });
            {
                defer ui.end(c);
                for (page.entries, 0..) |entry, index| {
                    ui.key(c, c.print("local-{d}-{s}", .{ page.cursor + index, entry.name }));
                    var row = ui.div(c).row().wFull().h(32).px(8).gap(8).itemsCenter().rounded(4).control();
                    if (self.selected == index) row = row.bg(c.theme.accent.alpha(0.18));
                    const interaction = row.interaction();
                    ui.text(c, if (entry.kind == .directory) "▸" else "·", .{ .color = c.theme.accent });
                    ui.text(c, entry.name, .{ .truncate = .middle });
                    ui.spacer(c);
                    if (entry.kind == .directory) {
                        ui.text(c, "目录", .{ .size = 11, .color = c.theme.muted });
                    } else {
                        ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "{d} B", .{entry.size});
                    }
                    row.end();
                    if (interaction.clicked) self.select(index) catch |err| self.setStatus("读取失败：{s}", .{@errorName(err)});
                }
                if (page.entries.len == 0) ui.text(c, "目录为空。", .{ .color = c.theme.muted });
            }
        } else {
            ui.spacer(c);
            ui.text(c, "选择目录或输入绝对路径开始只读浏览。", .{ .color = c.theme.muted });
        }
        if (self.preview) |*preview| {
            ui.divider(c);
            ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "临时预览：{s}", .{preview.path});
            switch (preview.kind) {
                .text => {
                    const limit = @min(preview.bytes.len, 64 * 1024);
                    var end = limit;
                    while (end > 0 and end < preview.bytes.len and preview.bytes[end] & 0xc0 == 0x80) end -= 1;
                    ui.scroll(c, .{ .width = .fill, .grow = 1, .height = .fill });
                    defer ui.end(c);
                    ui.text(c, preview.bytes[0..end], .{ .wrap = true, .mono = true });
                    if (end != preview.bytes.len) ui.text(c, "仅显示前 64 KiB；登记和固定版本仍针对完整文件。", .{ .color = c.theme.muted });
                },
                .image => {
                    if (!ui.image(c, .{ .key = c.print("local-preview-{x}", .{std.hash.Wyhash.hash(0x4c4f4341, preview.bytes)}), .source = .{ .encoded = preview.bytes }, .max_width = 720, .max_height = 240, .scale = 1 })) {
                        ui.text(c, "图片预览失败；文件仍可选择显式登记。", .{ .color = c.theme.danger });
                    }
                },
                .unsupported => ui.text(c, "当前格式不支持内置预览；仍可登记为普通只读资源。", .{ .color = c.theme.muted }),
            }
        }
        ui.text(c, self.status(), .{ .size = 12, .color = c.theme.muted });
    }
};

pub fn verify(state: anytype, tester: *ui.Tester) !void {
    try state.session.validate();
    if (state.files.current == null) return error.LocalBrowseMissing;
    const root = try state.allocator.dupe(u8, state.files.current.?.path);
    defer state.allocator.free(root);
    try tester.clickText("a.txt");
    try std.testing.expect(state.files.preview != null and state.files.preview.?.kind == .text);
    try std.testing.expect(tester.containsText("local text"));
    try tester.clickText("nested");
    try tester.clickText("打开选中项");
    try std.testing.expect(std.mem.endsWith(u8, state.files.current.?.path, "nested"));
    try tester.clickText("返回上级");
    try std.testing.expectEqualStrings(root, state.files.current.?.path);
    if (state.files.current.?.total > 128) {
        try tester.clickText("下一页");
        try std.testing.expect(state.files.current.?.cursor > 0);
        try state.files.open(root, 0);
    }
    const old_total = state.files.current.?.total;
    const added = try std.fs.path.join(state.allocator, &.{ root, "refresh.txt" });
    defer state.allocator.free(added);
    try std.Io.Dir.cwd().writeFile(state.ctx.io.?, .{ .sub_path = added, .data = "refresh observation" });
    try tester.clickText("刷新");
    try std.testing.expectEqual(old_total + 1, state.files.current.?.total);
    try tester.clickText("a.txt");
    try tester.clickText("收录到资源库");
    try std.testing.expect(state.page == .library and state.library.preview == null);
    state.showPage(.files);
    tester.frame();
    try tester.clickText("a.txt");
    try tester.clickText("收录到同名文件夹");
    try std.testing.expect(state.page == .library);
    const folder_label = std.fs.path.basename(root);
    var folder_id: ?u64 = null;
    for (state.library.catalog.items[0..state.library.catalog.count]) |item| {
        if (item.node_kind == .folder and item.parent_id == 0 and std.mem.eql(u8, item.label, folder_label)) {
            folder_id = item.id;
            break;
        }
    }
    try std.testing.expect(folder_id != null);
    var member_found = false;
    for (state.library.catalog.items[0..state.library.catalog.count]) |item| {
        if (item.node_kind == .resource and item.parent_id == folder_id.? and std.mem.eql(u8, item.label, "a.txt")) {
            member_found = true;
            break;
        }
    }
    try std.testing.expect(member_found);
    std.debug.print("CUTRANS_LOCAL_FOLDER_OK folder=1 member=1 label={s}\n", .{folder_label});
    state.showPage(.files);
    tester.frame();
    try tester.clickText("b.png");
    try std.testing.expect(state.files.preview != null and state.files.preview.?.kind == .image);
    try tester.clickText("收录到资源库");
    try std.testing.expect(state.page == .library and state.library.selected_library != 0);
    try tester.clickText("插入到文档");
    try std.testing.expect(state.page == .editor and state.ctx.document.nodes[0].op == .image);
    try std.testing.expect(std.mem.startsWith(u8, state.ctx.document.nodes[0].asset(), "library://"));
    state.showPage(.home);
    tester.frame();
    tester.drop(600, 400, &.{added}, "");
    tester.frame();
    var dropped = false;
    for (state.library.catalog.items[0..state.library.catalog.count]) |item| {
        if (item.node_kind == .resource and std.mem.eql(u8, item.label, "refresh.txt")) {
            dropped = true;
            break;
        }
    }
    try std.testing.expect(dropped and state.page == .library);
    const managed = try state.ctx.paths.dataPath(state.allocator, "managed-drop.txt");
    defer state.allocator.free(managed);
    try std.Io.Dir.cwd().writeFile(state.ctx.io.?, .{ .sub_path = managed, .data = "managed" });
    defer std.Io.Dir.cwd().deleteFile(state.ctx.io.?, managed) catch {};
    const before_managed = state.library.catalog.count;
    state.importDropped(&.{managed});
    try std.testing.expectEqual(before_managed, state.library.catalog.count);
    try std.testing.expect(std.mem.indexOf(u8, state.library.status(), "登记失败") != null);
    std.debug.print("CUTRANS_DROP_IMPORT_OK register_file=1 managed_root_refused=1\n", .{});
    std.debug.print("CUTRANS_LOCAL_FILES_OK browse=1 text=1 directory=1 page=1 refresh=1 register=1 folder=1 insert=1\n", .{});
}
