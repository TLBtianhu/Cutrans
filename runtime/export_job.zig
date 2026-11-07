//! export_job.zig — 一次协作式 PNG 导出的不可变输入

const std = @import("std");
const documents = @import("documents.zig");
const tasks = @import("tasks.zig");
const workspace = @import("vne").workspace;
const command = @import("command.zig");

pub const max_path = 1024;
pub const Phase = enum { queued, running, prepared, output_committed, succeeded, failed, cancelled, interrupted };

pub const Job = struct {
    task_id: tasks.Id,
    document: documents.Document,
    explicit_path: bool,
    path_bytes: [max_path]u8,
    path_len: u16,
    origin: workspace.Stamp = .{},
    source_fingerprint: u64 = 0,
    target_bytes: [max_path]u8 = undefined,
    target_len: u16 = 0,
    phase: Phase = .queued,
    output_hash: [32]u8 = @splat(0),
    output_size: u64 = 0,
    retry_of: ?tasks.Id = null,
    attempt: u32 = 1,
    /// Durable intent, distinct from a terminal cancelled outcome. The owner
    /// publishes it before signalling a worker and serializes it with commit.
    cancel_requested: bool = false,
    failure: ?command.Code = null,
    error_bytes: [96]u8 = undefined,
    error_len: u8 = 0,

    pub fn init(task_id: tasks.Id, document: documents.Document, arg: ?[]const u8) !Job {
        const path_text = arg orelse "exports/output.png";
        if (path_text.len == 0 or path_text.len > max_path) return error.InvalidResourcePath;
        if (arg != null) _ = @import("vne").uri.parse(path_text) catch return error.InvalidResourcePath;
        var result: Job = .{
            .task_id = task_id,
            .document = document,
            .explicit_path = arg != null,
            .path_bytes = undefined,
            .path_len = @intCast(path_text.len),
        };
        @memcpy(result.path_bytes[0..path_text.len], path_text);
        return result;
    }

    pub fn path(self: *const Job) []const u8 {
        return self.path_bytes[0..self.path_len];
    }

    /// New user intent creates a new identity while retaining the exact input
    /// version. The caller checks the parent's Task outcome and resolves a fresh
    /// output authorization; this helper never copies a saved physical target.
    pub fn retry(previous: *const Job, new_task_id: tasks.Id, new_target_arg: ?[]const u8) !Job {
        if (previous.task_id == 0 or new_task_id <= previous.task_id) return error.InvalidRetryIdentity;
        if (previous.attempt == 0 or (previous.retry_of == null and previous.attempt != 1) or
            (if (previous.retry_of) |id| id == 0 or id >= previous.task_id or previous.attempt == 1 else false)) return error.InvalidRetryLineage;
        const attempt = std.math.add(u32, previous.attempt, 1) catch return error.AttemptOverflow;
        if (previous.explicit_path) {
            const old_uri = try @import("vne").uri.parse(previous.path());
            if (old_uri.root == .external and new_target_arg == null) return error.RetryTargetRequired;
        }
        const arg = new_target_arg orelse if (previous.explicit_path) previous.path() else null;
        var result = try init(new_task_id, previous.document, arg);
        result.origin = previous.origin;
        result.source_fingerprint = previous.source_fingerprint;
        result.retry_of = previous.task_id;
        result.attempt = attempt;
        return result;
    }

    pub fn setTarget(self: *Job, value: []const u8) !void {
        if (value.len == 0 or value.len > self.target_bytes.len or !std.fs.path.isAbsolute(value) or std.mem.indexOfScalar(u8, value, 0) != null)
            return error.InvalidOutputTarget;
        @memcpy(self.target_bytes[0..value.len], value);
        self.target_len = @intCast(value.len);
    }

    pub fn target(self: *const Job) []const u8 {
        return self.target_bytes[0..self.target_len];
    }

    pub fn setError(self: *Job, value: []const u8) void {
        var length = @min(value.len, self.error_bytes.len);
        while (length > 0 and length < value.len and value[length] & 0xc0 == 0x80) length -= 1;
        @memcpy(self.error_bytes[0..length], value[0..length]);
        self.error_len = @intCast(length);
    }

    pub fn errorText(self: *const Job) []const u8 {
        return self.error_bytes[0..self.error_len];
    }

    /// Expose only initialized slices, never the unused tails of fixed buffers.
    /// The current eight-node document fits this bounded canonical workspace.
    pub fn jsonStringify(self: *const Job, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        var buffer: [64 * 1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        const canonical = documents.emitAlloc(&self.document, fixed.allocator()) catch return error.WriteFailed;
        const digest = std.fmt.bytesToHex(self.output_hash, .lower);
        try writer.write(.{
            .task_id = self.task_id,
            .operation = "image.png.export/1",
            .document = canonical,
            .fingerprint = self.document.fingerprint(),
            .node_id_high_water = self.document.nodeIdHighWater(),
            .origin = self.origin,
            .source_fingerprint = self.source_fingerprint,
            .path = self.path(),
            .explicit_path = self.explicit_path,
            .target = self.target(),
            .phase = self.phase,
            .output_hash = digest[0..],
            .output_size = self.output_size,
            .retry_of = self.retry_of,
            .attempt = self.attempt,
            .cancel_requested = self.cancel_requested,
            .failure = self.failure,
            .error_text = self.errorText(),
        });
    }
};
