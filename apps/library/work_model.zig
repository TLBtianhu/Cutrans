//! UI-owned live text; the VM owns durable drafts and published work revisions.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const abi = @import("vne").abi;
const resource = @import("vne").resource_api;
const TextEditor = @import("text_editor.zig").Editor;

const Pending = struct {
    request: resource.WorkRequest,
    label: []u8,
    body: []u8,
    generation: u64,

    fn deinit(self: Pending, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.body);
    }
};

const Session = struct {
    id: u64,
    editor: TextEditor,
    work_revision: u64,
    base_revision: u64,
    draft_revision: u64,
    generation: u64 = 0,
    persisted_generation: u64 = 0,
    last_edit_generation: u64 = 0,
    last_edit_ns: i96 = 0,
    want_commit: bool = false,
    requires_protection: bool = false,

    fn needsDraft(self: *const Session) bool {
        return self.requires_protection or self.generation != self.persisted_generation;
    }
};

/// Draft autosave is idle-debounced: a keystroke changes `generation`, a later
/// frame persists it, and `beforeClose`/Ctrl+S force an immediate flush.
const save_debounce_ns: i96 = 400 * std.time.ns_per_ms;

const OwnedSnapshot = struct {
    metadata: resource.WorkSnapshot,
    body: []u8,

    fn deinit(self: OwnedSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    authority: ?resource.Api = null,
    io: ?std.Io = null,
    editor: ?Session = null,
    pending: ?Pending = null,
    identity: ?[2]u64 = null,
    next_sequence: u64 = 1,
    paused: bool = false,
    failure: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, shell_api: *const abi.ShellApi, io: ?std.Io) Model {
        var result = Model{ .allocator = allocator, .io = io };
        var authority: resource.Api = undefined;
        if (shell_api.resource_api(shell_api.context, &authority) == abi.Status.ok and authority.isCurrent()) result.authority = authority;
        return result;
    }

    pub fn deinit(self: *Model) void {
        if (self.pending) |pending| pending.deinit(self.allocator);
        if (self.editor) |*session| session.editor.deinit();
        self.* = undefined;
    }

    pub fn canLeave(self: *const Model) bool {
        if (self.pending != null) return false;
        const session = self.editor orelse return true;
        return !session.needsDraft() and !session.want_commit and !session.editor.isComposing() and
            session.editor.pending_paste == null and !session.editor.pending_change;
    }

    pub fn close(self: *Model) !void {
        if (!self.canLeave()) return error.WorkEditPending;
        if (self.editor) |*session| session.editor.deinit();
        self.editor = null;
        self.paused = false;
        self.failure = null;
    }

    fn read(self: *Model, id: u64) !OwnedSnapshot {
        const authority = self.authority orelse return error.WorkApiUnavailable;
        var metadata: resource.WorkSnapshot = undefined;
        var required: usize = 0;
        const query = authority.work_snapshot(authority.context, id, null, &metadata, null, 0, &required);
        if (query == resource.Status.wrong_kind) return error.NotWorkResource;
        if (query != abi.Status.buffer_too_small) return error.WorkSnapshotFailed;
        if (metadata.struct_size != @sizeOf(resource.WorkSnapshot) or metadata.api_version != resource.version or
            metadata.resource_id != id or metadata.body_len != required or required > resource.max_work_body_size) return error.InvalidWorkSnapshot;
        const body = try self.allocator.alloc(u8, required);
        errdefer self.allocator.free(body);
        var actual: resource.WorkSnapshot = undefined;
        var copied: usize = 0;
        const status = authority.work_snapshot(authority.context, id, &metadata, &actual, body.ptr, body.len, &copied);
        if (status != abi.Status.ok or copied != required or !std.meta.eql(actual, metadata)) return error.WorkSnapshotChanged;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        if (!std.mem.eql(u8, &digest, &actual.body_hash)) return error.InvalidWorkSnapshot;
        return .{ .metadata = actual, .body = body };
    }

    pub fn open(self: *Model, id: u64) !void {
        if (!self.canLeave()) return error.WorkEditPending;
        const snapshot = try self.read(id);
        defer snapshot.deinit(self.allocator);
        if (!std.unicode.utf8ValidateSlice(snapshot.body) or std.mem.indexOfScalar(u8, snapshot.body, 0) != null or snapshot.body.len > @import("text_editor.zig").max_text_bytes) return error.UnsupportedWorkText;
        var editor = try TextEditor.init(self.allocator, snapshot.body);
        errdefer editor.deinit();
        editor.focus();
        if (self.editor) |*old| old.editor.deinit();
        self.editor = .{
            .id = id,
            .editor = editor,
            .work_revision = snapshot.metadata.work_revision,
            .base_revision = snapshot.metadata.base_revision,
            .draft_revision = snapshot.metadata.draft_revision,
        };
        self.paused = false;
        self.failure = null;
    }

    fn ensureIdentity(self: *Model) ![2]u64 {
        if (self.identity) |value| return value;
        const io = self.io orelse return error.ClientEntropyUnavailable;
        var value: [2]u64 = undefined;
        try io.randomSecure(std.mem.asBytes(&value));
        if (value[0] == 0 and value[1] == 0) return error.ClientEntropyUnavailable;
        self.identity = value;
        self.next_sequence = 1;
        return value;
    }

    fn fail(self: *Model, err: anyerror) void {
        self.paused = true;
        self.failure = @errorName(err);
        if (self.editor) |*session| {
            session.requires_protection = true;
            session.want_commit = false;
        }
    }

    fn statusName(code: i32) []const u8 {
        return switch (code) {
            resource.Status.stale_version => "StaleWorkRevision",
            resource.Status.draft_conflict => "DraftConflict",
            resource.Status.request_conflict => "RequestConflict",
            resource.Status.receipt_expired => "ReceiptExpired",
            resource.Status.bad_sequence => "BadSequence",
            resource.Status.receipt_limit => "ReceiptLimit",
            resource.Status.wrong_kind => "NotEditableResource",
            resource.Status.content_mismatch => "WorkContentMismatch",
            abi.Status.out_of_memory => "OutOfMemory",
            abi.Status.not_ready => "HostNotReady",
            abi.Status.not_found => "ResourceNotFound",
            abi.Status.queue_full => "ResourceCapacityReached",
            else => "WorkRequestRejected",
        };
    }

    fn sendPending(self: *Model) !?u64 {
        const authority = self.authority orelse return error.WorkApiUnavailable;
        const pending = self.pending orelse return error.NoPendingWorkRequest;
        var outcome: resource.WorkOutcome = undefined;
        const transport = authority.work_submit(authority.context, &pending.request, &outcome);
        if (transport != abi.Status.ok) {
            self.fail(error.WorkResultUnknown);
            return error.WorkResultUnknown;
        }
        if (outcome.struct_size != @sizeOf(resource.WorkOutcome) or outcome.api_version != resource.version or
            outcome.sequence != pending.request.sequence or std.enums.fromInt(resource.Disposition, outcome.disposition) == null)
        {
            self.fail(error.InvalidWorkOutcome);
            return error.InvalidWorkOutcome;
        }
        if (outcome.status == abi.Status.ok and (outcome.resource_id == 0 or outcome.work_revision == 0)) {
            self.fail(error.InvalidWorkOutcome);
            return error.InvalidWorkOutcome;
        }
        const mode = std.enums.fromInt(resource.WorkMode, pending.request.mode).?;
        const generation = pending.generation;
        const resource_id = pending.request.resource_id;
        pending.deinit(self.allocator);
        self.pending = null;
        if (self.next_sequence == std.math.maxInt(u64)) {
            self.identity = null;
            self.next_sequence = 1;
        } else self.next_sequence += 1;
        if (outcome.status != abi.Status.ok) {
            self.paused = true;
            self.failure = statusName(outcome.status);
            if (self.editor) |*session| {
                session.requires_protection = true;
                session.want_commit = false;
            }
            return error.WorkRequestRejected;
        }
        if (outcome.resource_id == 0 or outcome.work_revision == 0) {
            self.fail(error.InvalidWorkOutcome);
            return error.InvalidWorkOutcome;
        }
        switch (mode) {
            .create => {
                self.failure = null;
                self.paused = false;
                return outcome.resource_id;
            },
            .save_draft => {
                const session = if (self.editor) |*value| value else {
                    self.fail(error.WorkEditorMissing);
                    return error.WorkEditorMissing;
                };
                if (session.id != resource_id or outcome.resource_id != session.id) {
                    self.fail(error.WorkEditorChanged);
                    return error.WorkEditorChanged;
                }
                session.work_revision = outcome.work_revision;
                session.draft_revision = outcome.draft_revision;
                session.persisted_generation = generation;
                session.requires_protection = false;
            },
            .commit => {
                const session = if (self.editor) |*value| value else {
                    self.fail(error.WorkEditorMissing);
                    return error.WorkEditorMissing;
                };
                if (session.id != resource_id or outcome.resource_id != session.id or outcome.draft_revision != 0) {
                    self.fail(error.WorkEditorChanged);
                    return error.WorkEditorChanged;
                }
                session.work_revision = outcome.work_revision;
                session.base_revision = outcome.work_revision;
                session.draft_revision = 0;
                session.persisted_generation = generation;
                session.want_commit = false;
                session.requires_protection = false;
            },
            .discard => {
                const session = if (self.editor) |*value| value else return error.WorkEditorMissing;
                session.draft_revision = 0;
                session.base_revision = outcome.work_revision;
            },
        }
        self.paused = false;
        self.failure = null;
        return null;
    }

    fn start(self: *Model, mode: resource.WorkMode, id: u64, base: u64, draft: u64, label: []const u8, body: []const u8, generation: u64) !?u64 {
        if (self.pending != null) return error.WorkResultUnknown;
        const identity = try self.ensureIdentity();
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        const owned_body = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(owned_body);
        self.pending = .{
            .request = .{
                .client_hi = identity[0],
                .client_lo = identity[1],
                .sequence = self.next_sequence,
                .resource_id = id,
                .base_revision = base,
                .expected_draft_revision = draft,
                .mode = @backingInt(mode),
                .label = .{ .ptr = if (owned_label.len == 0) null else owned_label.ptr, .len = owned_label.len },
                .body = .{ .ptr = if (owned_body.len == 0) null else owned_body.ptr, .len = owned_body.len },
            },
            .label = owned_label,
            .body = owned_body,
            .generation = generation,
        };
        return self.sendPending();
    }

    pub fn create(self: *Model, label: []const u8) !u64 {
        if (!self.canLeave()) return error.WorkEditPending;
        const result = try self.start(.create, 0, 0, 0, label, "", 0);
        return result orelse error.WorkReceiptMissing;
    }

    pub fn pump(self: *Model, force: bool) !void {
        if (self.pending != null or self.paused) return;
        const session = if (self.editor) |*value| value else return;
        if (session.editor.isComposing()) return;
        if (session.needsDraft()) {
            if (!force) {
                if (self.io) |io| {
                    const now = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
                    // A new edit restarts the idle window. Later frames keep the
                    // window alive without writing anything until it expires.
                    if (session.last_edit_generation != session.generation) {
                        session.last_edit_generation = session.generation;
                        session.last_edit_ns = now;
                        return;
                    }
                    if (now - session.last_edit_ns < save_debounce_ns) return;
                }
            }
            _ = try self.start(.save_draft, session.id, session.base_revision, session.draft_revision, "", session.editor.text(), session.generation);
            session.last_edit_generation = session.generation;
        } else if (session.want_commit) {
            if (session.draft_revision == 0) {
                session.want_commit = false;
                return;
            }
            _ = try self.start(.commit, session.id, 0, session.draft_revision, "", "", session.generation);
        }
    }

    /// The UI must schedule a timer frame while a draft is awaiting its idle
    /// window, otherwise a user who stops typing would never persist it.
    pub fn needsFrame(self: *const Model) bool {
        if (self.paused) return false;
        if (self.pending != null) return true;
        const session = self.editor orelse return false;
        if (session.editor.isComposing()) return false;
        return session.needsDraft() or session.want_commit;
    }

    pub fn requestSave(self: *Model) !void {
        self.paused = false;
        self.failure = null;
        if (self.editor) |*session| session.want_commit = true;
        if (self.pending != null) {
            _ = try self.sendPending();
        }
        try self.pump(true);
    }

    pub fn beforeClose(self: *Model) bool {
        for (0..4) |_| {
            if (self.canLeave()) return true;
            self.pump(true) catch return false;
        }
        return self.canLeave();
    }

    pub fn view(self: *Model, c: *ui.Context) !void {
        const session = if (self.editor) |*value| value else return;
        if (c.shortcut(.{ .key = 's', .ctrl = true })) self.requestSave() catch |err| self.fail(err);
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        {
            defer ui.end(c);
            ui.text(c, "工作正文", .{ .size = 17, .weight = .semibold });
            ui.spacer(c);
            if (ui.button(c, "撤销", .{ .disabled = !session.editor.canUndo() }).clicked) _ = try session.editor.undo();
            if (ui.button(c, "重做", .{ .disabled = !session.editor.canRedo() }).clicked) _ = try session.editor.redo();
            if (ui.button(c, "保存正文", .{ .variant = .primary, .disabled = session.editor.isComposing() }).clicked) self.requestSave() catch {};
        }
        ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "工作 revision {d} · {s}", .{
            session.work_revision,
            if (session.draft_revision == 0) "无未提交草稿" else "草稿已持久保护",
        });
        const lines: u16 = @intFromFloat(std.math.clamp((c.size.h - 220) / 23, 5, 50));
        const result = try session.editor.view(c, lines);
        if (result.changed) session.generation += 1;
        ui.spacer(c);
        if (self.failure) |message| {
            ui.textf(c, .{ .color = c.theme.danger, .wrap = true }, "输入仍保留：{s} · 点击保存正文重试", .{message});
        } else {
            const text = if (result.composing) "正在组词 · 完成后保存草稿" else if (self.pending != null or session.needsDraft())
                "正在保存草稿…"
            else if (session.draft_revision != 0)
                "草稿已保存 · 尚未提交正文"
            else
                "正文已保存";
            ui.text(c, text, .{ .size = 12, .color = c.theme.muted });
        }
        ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "{d} 字节 · Ctrl+S 提交 · 最多 1 MiB", .{session.editor.text().len});
        if (self.needsFrame()) c.frameIn(0.05);
    }
};
