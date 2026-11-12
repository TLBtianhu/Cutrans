//! Unpublished document/history change. Persist a borrowed history view first,
//! then publish the cheap document value and the changed history slot/cursor.
const std = @import("std");
const documents = @import("vne").documents;
const history = @import("history.zig");
const journal = @import("history_journal.zig");
const RuntimeContext = @import("context.zig").Context;

pub const Candidate = struct {
    document: documents.Document,
    base_count: usize,
    base_cursor: usize,
    base_fingerprint: u64,
    base_high_water: u64,
    base_dirty: bool,
    base_revision: u64,
    action: union(enum) { none, record: history.Edit, undo, redo } = .none,

    pub fn init(ctx: *const RuntimeContext) Candidate {
        return .{
            .document = ctx.document,
            .base_count = ctx.history.count,
            .base_cursor = ctx.history.cursor,
            .base_fingerprint = ctx.document.fingerprint(),
            .base_high_water = ctx.document.nodeIdHighWater(),
            .base_dirty = ctx.document.dirty,
            .base_revision = ctx.document_revision,
        };
    }

    pub fn record(self: *Candidate, ctx: *const RuntimeContext, edit: history.Edit) !void {
        if (self.action != .none) return error.EditAlreadyStaged;
        if (self.base_cursor >= ctx.history.entries.len) return error.HistoryFull;
        self.action = .{ .record = edit };
    }

    pub fn undo(self: *Candidate, ctx: *const RuntimeContext) bool {
        if (self.action != .none or self.base_cursor == 0) return false;
        if (!history.applyUndo(ctx.history.entries[self.base_cursor - 1], &self.document)) return false;
        self.action = .undo;
        return true;
    }

    pub fn redo(self: *Candidate, ctx: *const RuntimeContext) bool {
        if (self.action != .none or self.base_cursor == self.base_count) return false;
        if (!history.applyRedo(ctx.history.entries[self.base_cursor], &self.document)) return false;
        self.action = .redo;
        return true;
    }

    fn view(self: *const Candidate, ctx: *const RuntimeContext) !journal.View {
        return switch (self.action) {
            .none => error.NoEditStaged,
            .record => |*edit| .{ .entries = ctx.history.entries[0..self.base_cursor], .appended = edit, .cursor = self.base_cursor + 1 },
            .undo => .{ .entries = ctx.history.entries[0..self.base_count], .cursor = self.base_cursor - 1 },
            .redo => .{ .entries = ctx.history.entries[0..self.base_count], .cursor = self.base_cursor + 1 },
        };
    }

    /// The VM's single writer calls this before exposing a successful command.
    /// This is not a cross-thread lock or a transaction over external files.
    pub fn commit(self: *const Candidate, ctx: *RuntimeContext) !void {
        if (ctx.document_revision != self.base_revision or
            ctx.history.count != self.base_count or ctx.history.cursor != self.base_cursor or
            ctx.document.fingerprint() != self.base_fingerprint or ctx.document.nodeIdHighWater() != self.base_high_water or
            ctx.document.dirty != self.base_dirty) return error.StaleEditCandidate;
        const snapshot = try self.view(ctx);
        // Check before touching the journal: wrapping a publication identity
        // would make an old request look current again.
        if (ctx.document_revision == std.math.maxInt(u64)) return error.DocumentRevisionOverflow;
        if (ctx.io != null and ctx.paths.data_dir.len != 0) {
            var dir = try ctx.paths.openDataDir(ctx.io.?, ctx.allocator);
            defer dir.close(ctx.io.?);
            try journal.saveView(snapshot, &self.document, ctx.allocator, ctx.io.?, dir);
        }
        switch (self.action) {
            .record => |edit| {
                ctx.history.entries[self.base_cursor] = edit;
                ctx.history.count = self.base_cursor + 1;
                ctx.history.cursor = self.base_cursor + 1;
            },
            .undo => ctx.history.cursor = self.base_cursor - 1,
            .redo => ctx.history.cursor = self.base_cursor + 1,
            .none => unreachable,
        }
        ctx.document = self.document;
        ctx.document_revision += 1;
    }
};
