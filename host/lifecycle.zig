const std = @import("std");
const protocol = @import("vne").host_protocol;
const launch = @import("vne").launch;
const abi = @import("vne").abi;
const control = @import("ports").host_control;

fn lifecyclePath(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ data_dir, protocol.lifecycle_path });
}

pub fn readPersisted(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, mode: launch.Mode) !protocol.Snapshot {
    const path = try lifecyclePath(allocator, data_dir);
    defer allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(protocol.max_message)) catch |err| {
        if (err == error.FileNotFound) return .{ .mode = mode, .abi_version = abi.version };
        return err;
    };
    defer allocator.free(text);
    const snapshot = try protocol.parseSnapshot(text);
    if (snapshot.mode != mode) return error.HostInstanceModeMismatch;
    return snapshot;
}

fn request(allocator: std.mem.Allocator, endpoint: []const u8, action: protocol.Action) !protocol.Snapshot {
    var output: [protocol.max_message]u8 = undefined;
    const encoded = try protocol.writeAction(&output, action);
    var input: [protocol.max_message]u8 = undefined;
    const count = try control.request(allocator, endpoint, encoded, &input);
    return protocol.parseSnapshot(input[0..count]);
}

pub fn status(allocator: std.mem.Allocator, endpoint: []const u8) !protocol.Snapshot {
    return request(allocator, endpoint, .status);
}

pub fn stop(allocator: std.mem.Allocator, endpoint: []const u8) !protocol.Snapshot {
    return request(allocator, endpoint, .stop);
}

pub const Request = struct {
    allocator: std.mem.Allocator,
    connection: control.Connection,
    action: protocol.Action,
    rpc: ?@import("shell").protocol.Request = null,
    payload: []u8 = &.{},

    pub fn deinit(self: *Request) void {
        if (self.payload.len > 0) self.allocator.free(self.payload);
        self.connection.deinit();
        self.* = undefined;
    }

    pub fn reply(self: *Request, snapshot: protocol.Snapshot) !void {
        var buffer: [protocol.max_message]u8 = undefined;
        const encoded = try protocol.writeSnapshot(&buffer, snapshot);
        try self.connection.writeMessage(encoded);
    }

    pub fn replyRpc(self: *Request, status_code: i32, value: u64, payload: []const u8) !void {
        const rpc = self.rpc orelse return error.InvalidShellRequest;
        var header: [@import("shell").protocol.header_size]u8 = undefined;
        const encoded = try @import("shell").protocol.writeResponse(&header, .{
            .kind = rpc.kind,
            .status = status_code,
            .value = value,
            .payload_len = @intCast(payload.len),
        });
        try self.connection.writeMessage(encoded);
        if (payload.len > 0) try self.connection.writeMessage(payload);
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    endpoint: []u8,
    lock: control.Lock,
    current: protocol.Snapshot,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, mode: launch.Mode) !Server {
        if (!std.fs.path.isAbsolute(data_dir)) return error.InvalidDataDirectory;
        var lock = try control.acquireLock(allocator, io, data_dir);
        errdefer lock.deinit();
        const endpoint = try protocol.endpoint(allocator, data_dir);
        errdefer allocator.free(endpoint);
        const previous = try readPersisted(allocator, io, data_dir, mode);
        var self = Server{
            .allocator = allocator,
            .io = io,
            .data_dir = data_dir,
            .endpoint = endpoint,
            .lock = lock,
            .current = .{
                .state = .starting,
                .mode = mode,
                .boot_id = previous.boot_id + 1,
                .last_shutdown_abnormal = previous.state != .stopped,
                .abi_version = abi.version,
            },
        };
        errdefer self.deinit();
        try self.persist();
        return self;
    }

    pub fn deinit(self: *Server) void {
        self.lock.deinit();
        self.allocator.free(self.endpoint);
        self.* = undefined;
    }

    fn persist(self: *Server) !void {
        var buffer: [protocol.max_message]u8 = undefined;
        const encoded = try protocol.writeSnapshot(&buffer, self.current);
        const path = try lifecyclePath(self.allocator, self.data_dir);
        defer self.allocator.free(path);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{ .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, encoded);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }

    pub fn ready(self: *Server, document_fingerprint: u64) !void {
        if (self.current.state != .starting) return error.InvalidHostState;
        self.current.document_fingerprint = document_fingerprint;
        self.current.state = .running;
        try self.persist();
    }

    pub fn snapshot(self: *Server, document_fingerprint: u64, present_count: u64) protocol.Snapshot {
        self.current.document_fingerprint = document_fingerprint;
        self.current.present_count = present_count;
        return self.current;
    }

    pub fn beginStop(self: *Server) !void {
        if (self.current.state != .running and self.current.state != .degraded) return error.InvalidHostState;
        self.current.state = .stopping;
        try self.persist();
    }

    pub fn completeStop(self: *Server) !void {
        if (self.current.state != .stopping) return error.InvalidHostState;
        self.current.state = .stopped;
        self.current.last_shutdown_abnormal = false;
        try self.persist();
    }

    pub fn failStop(self: *Server) !void {
        self.current.state = .degraded;
        try self.persist();
    }

    pub fn accept(self: *Server) !Request {
        var connection = try control.accept(self.allocator, self.endpoint);
        errdefer connection.deinit();
        var buffer: [protocol.max_message]u8 = undefined;
        const count = try connection.readMessage(&buffer);
        if (@import("shell").protocol.isRequest(buffer[0..count])) {
            const rpc = try @import("shell").protocol.parseRequest(buffer[0..count]);
            var payload: []u8 = &.{};
            if (rpc.payload_len > 0) payload = try self.allocator.alloc(u8, rpc.payload_len);
            errdefer if (payload.len > 0) self.allocator.free(payload);
            if (payload.len > 0) {
                const received = try connection.readMessage(payload);
                if (received != payload.len) return error.InvalidShellRequest;
            }
            return .{ .allocator = self.allocator, .connection = connection, .action = .rpc, .rpc = rpc, .payload = payload };
        }
        const action = try protocol.parseAction(buffer[0..count]);
        return .{ .allocator = self.allocator, .connection = connection, .action = action };
    }
};

test "host lifecycle records normal stops and abnormal recovery without a pid heuristic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var first = try Server.init(std.testing.allocator, std.testing.io, root, .portable);
    try std.testing.expectEqual(@as(u64, 1), first.current.boot_id);
    try first.ready(42);
    try std.testing.expectError(error.HostAlreadyRunning, Server.init(std.testing.allocator, std.testing.io, root, .portable));
    first.deinit();

    var recovered = try Server.init(std.testing.allocator, std.testing.io, root, .portable);
    try std.testing.expectEqual(@as(u64, 2), recovered.current.boot_id);
    try std.testing.expect(recovered.current.last_shutdown_abnormal);
    try recovered.ready(42);
    try recovered.beginStop();
    try recovered.completeStop();
    recovered.deinit();

    const stopped = try readPersisted(std.testing.allocator, std.testing.io, root, .portable);
    try std.testing.expectEqual(protocol.State.stopped, stopped.state);
    try std.testing.expect(!stopped.last_shutdown_abnormal);
    try std.testing.expectEqual(@as(u64, 2), stopped.boot_id);
    try std.testing.expectEqual(@as(u64, 42), stopped.document_fingerprint);
}
