const std = @import("std");
const builtin = @import("builtin");
const max_message = 1024;

const PIPE_ACCESS_DUPLEX: u32 = 3;
const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x00080000;
const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
const PIPE_TYPE_MESSAGE: u32 = 4;
const PIPE_READMODE_MESSAGE: u32 = 2;
const PIPE_WAIT: u32 = 0;
const PIPE_REJECT_REMOTE_CLIENTS: u32 = 8;
const OPEN_EXISTING: u32 = 3;
const OPEN_ALWAYS: u32 = 4;
const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const ERROR_PIPE_CONNECTED: u32 = 535;
const ERROR_IO_PENDING: u32 = 997;
const WAIT_OBJECT_0: u32 = 0;
const WAIT_TIMEOUT: u32 = 258;
const INFINITE: u32 = 0xffffffff;
pub const message_timeout_ms: u32 = 5000;
const invalid_handle: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: u32 = 0,
    OffsetHigh: u32 = 0,
    hEvent: ?*anyopaque = null,
};

extern fn CreateNamedPipeW(name: [*:0]const u16, open_mode: u32, pipe_mode: u32, max_instances: u32, out_buffer_size: u32, in_buffer_size: u32, default_timeout: u32, security_attributes: ?*anyopaque) ?*anyopaque;
extern fn ConnectNamedPipe(pipe: ?*anyopaque, overlapped: ?*anyopaque) i32;
extern fn DisconnectNamedPipe(pipe: ?*anyopaque) i32;
extern fn SetNamedPipeHandleState(pipe: ?*anyopaque, mode: ?*const u32, max_collection_count: ?*const u32, collect_timeout: ?*const u32) i32;
extern fn CreateFileW(name: [*:0]const u16, desired_access: u32, share_mode: u32, security_attributes: ?*anyopaque, creation_disposition: u32, flags_and_attributes: u32, template_file: ?*anyopaque) ?*anyopaque;
extern fn ReadFile(file: ?*anyopaque, buffer: ?*anyopaque, bytes_to_read: u32, bytes_read: ?*u32, overlapped: ?*anyopaque) i32;
extern fn WriteFile(file: ?*anyopaque, buffer: ?*const anyopaque, bytes_to_write: u32, bytes_written: ?*u32, overlapped: ?*anyopaque) i32;
extern fn CreateEventW(attributes: ?*anyopaque, manual_reset: i32, initial_state: i32, name: ?[*:0]const u16) ?*anyopaque;
extern fn WaitForSingleObject(handle: ?*anyopaque, milliseconds: u32) u32;
extern fn GetOverlappedResult(file: ?*anyopaque, overlapped: *anyopaque, transferred: *u32, wait: i32) i32;
extern fn CancelIoEx(file: ?*anyopaque, overlapped: *anyopaque) i32;
extern fn GetLastError() u32;
extern fn CloseHandle(handle: ?*anyopaque) i32;
extern fn Sleep(milliseconds: u32) void;

pub const Connection = struct {
    handle: ?*anyopaque,
    server_side: bool,
    replied: bool = false,
    failed: bool = false,

    pub fn deinit(self: *Connection) void {
        if (self.server_side) {
            if (self.replied and !self.failed) {
                // One request owns one connection. Existing clients close only
                // after reading the complete reply. Keep queued reply bytes
                // available until that close, with a bounded wait for peers
                // which never read/close. Extra input violates this protocol.
                var extra: [1]u8 = undefined;
                _ = ioOverlapped(self.handle, &extra, false, message_timeout_ms) catch 0;
            }
            _ = DisconnectNamedPipe(self.handle);
        }
        _ = CloseHandle(self.handle);
        self.* = undefined;
    }

    pub fn readMessage(self: *Connection, buffer: []u8) !usize {
        return ioOverlapped(self.handle, buffer, false, message_timeout_ms) catch |err| {
            self.failed = true;
            return err;
        };
    }

    pub fn writeMessage(self: *Connection, bytes: []const u8) !void {
        _ = ioOverlapped(self.handle, @constCast(bytes), true, message_timeout_ms) catch |err| {
            self.failed = true;
            return err;
        };
        self.replied = self.server_side;
    }
};

fn wide(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

pub fn accept(allocator: std.mem.Allocator, endpoint: []const u8) !Connection {
    return acceptTimeout(allocator, endpoint, INFINITE);
}

fn acceptTimeout(allocator: std.mem.Allocator, endpoint: []const u8, timeout_ms: u32) !Connection {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const name = try wide(allocator, endpoint);
    defer allocator.free(name);
    const handle = CreateNamedPipeW(name.ptr, PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED, PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, max_message, max_message, 1000, null);
    if (handle == null or handle == invalid_handle) return error.HostPipeCreateFailed;
    errdefer _ = CloseHandle(handle);
    const event = CreateEventW(null, 1, 0, null) orelse return error.HostIoFailed;
    defer _ = CloseHandle(event);
    var overlapped = OVERLAPPED{ .hEvent = event };
    if (ConnectNamedPipe(handle, &overlapped) == 0) {
        switch (GetLastError()) {
            ERROR_PIPE_CONNECTED => {},
            ERROR_IO_PENDING => {
                var transferred: u32 = 0;
                try waitOperation(handle, &overlapped, timeout_ms, &transferred);
            },
            else => return error.HostPipeConnectFailed,
        }
    }
    return .{ .handle = handle, .server_side = true };
}

pub fn connect(allocator: std.mem.Allocator, endpoint: []const u8) !Connection {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const name = try wide(allocator, endpoint);
    defer allocator.free(name);
    for (0..100) |_| {
        const handle = CreateFileW(name.ptr, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, null);
        if (handle != null and handle != invalid_handle) {
            const mode: u32 = PIPE_READMODE_MESSAGE;
            if (SetNamedPipeHandleState(handle, &mode, null, null) == 0) {
                _ = CloseHandle(handle);
                return error.HostPipeConnectFailed;
            }
            return .{ .handle = handle, .server_side = false };
        }
        Sleep(10);
    }
    return error.HostUnavailable;
}

fn waitOperation(handle: ?*anyopaque, overlapped: *OVERLAPPED, timeout_ms: u32, transferred: *u32) !void {
    const waited = WaitForSingleObject(overlapped.hEvent, timeout_ms);
    if (waited != WAIT_OBJECT_0) {
        _ = CancelIoEx(handle, overlapped);
        // Cancellation is a request, including the race where it reports
        // ERROR_NOT_FOUND because I/O just completed. The kernel must finish
        // using this OVERLAPPED and its buffer before either can leave scope.
        _ = GetOverlappedResult(handle, overlapped, transferred, 1);
        return if (waited == WAIT_TIMEOUT) error.HostTimeout else error.HostIoFailed;
    }
    if (GetOverlappedResult(handle, overlapped, transferred, 0) == 0) return error.HostUnavailable;
}

fn ioOverlapped(handle: ?*anyopaque, buffer: []u8, write: bool, timeout_ms: u32) !usize {
    const event = CreateEventW(null, 1, 0, null) orelse return error.HostIoFailed;
    defer _ = CloseHandle(event);
    var overlapped = OVERLAPPED{ .hEvent = event };
    var transferred: u32 = 0;
    const completed = if (write)
        WriteFile(handle, buffer.ptr, @intCast(buffer.len), &transferred, &overlapped)
    else
        ReadFile(handle, buffer.ptr, @intCast(buffer.len), &transferred, &overlapped);
    if (completed == 0) {
        const code = GetLastError();
        if (code != ERROR_IO_PENDING) return error.HostUnavailable;
        try waitOperation(handle, &overlapped, timeout_ms, &transferred);
    }
    if (write and transferred != buffer.len) return error.HostWriteFailed;
    if (!write and transferred == 0) return error.HostUnavailable;
    return transferred;
}

pub fn request(allocator: std.mem.Allocator, endpoint: []const u8, message: []const u8, response: []u8) !usize {
    var connection = try connect(allocator, endpoint);
    defer connection.deinit();
    _ = try ioOverlapped(connection.handle, @constCast(message), true, message_timeout_ms);
    return ioOverlapped(connection.handle, response, false, message_timeout_ms);
}

pub const Lock = struct {
    handle: ?*anyopaque,

    pub fn deinit(self: *Lock) void {
        _ = CloseHandle(self.handle);
        self.* = undefined;
    }
};

pub fn acquireLock(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !Lock {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const session = try std.fs.path.join(allocator, &.{ data_dir, "session" });
    defer allocator.free(session);
    try std.Io.Dir.cwd().createDirPath(io, session);
    const path = try std.fs.path.join(allocator, &.{ session, "host.lock" });
    defer allocator.free(path);
    const name = try wide(allocator, path);
    defer allocator.free(name);
    const handle = CreateFileW(name.ptr, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_ALWAYS, 0, null);
    if (handle == null or handle == invalid_handle) return error.HostAlreadyRunning;
    return .{ .handle = handle };
}

test "host control ABI matches Windows x64 and retains a real exclusive instance lock" {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (builtin.cpu.arch == .x86_64) try std.testing.expectEqual(@as(usize, 32), @sizeOf(OVERLAPPED));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var first = try acquireLock(std.testing.allocator, std.testing.io, root);
    defer first.deinit();
    try std.testing.expectError(error.HostAlreadyRunning, acquireLock(std.testing.allocator, std.testing.io, root));
}

fn testEndpoint() ![]u8 {
    var nonce: [16]u8 = undefined;
    try std.testing.io.randomSecure(&nonce);
    const hex = std.fmt.bytesToHex(nonce, .lower);
    return std.fmt.allocPrint(std.testing.allocator, "\\\\.\\pipe\\cutrans-transport-test-{s}", .{hex});
}

fn waitTestEvent(event: *std.Io.Event) !void {
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .raw = .{ .nanoseconds = 3 * std.time.ns_per_s }, .clock = .awake });
    while (!event.isSet()) {
        event.waitTimeout(std.testing.io, .{ .deadline = deadline }) catch |err| {
            if (err != error.Timeout or std.Io.Clock.Timestamp.compare(.now(std.testing.io, .awake), .gte, deadline)) return err;
        };
    }
}

const TransportTest = struct {
    endpoint: []const u8,
    mode: enum { slow_reader, small_reply, read_cancel, write_cancel },
    timeout_finished: std.Io.Event = .unset,
    response_written: std.Io.Event = .unset,
    result: anyerror!void = undefined,

    fn run(self: *TransportTest) void {
        self.result = self.serve();
    }

    fn serve(self: *TransportTest) !void {
        var connection = try acceptTimeout(std.testing.allocator, self.endpoint, 1000);
        defer connection.deinit();
        switch (self.mode) {
            .slow_reader, .small_reply => {
                var request_buffer: [16]u8 = undefined;
                const count = try connection.readMessage(&request_buffer);
                if (!std.mem.eql(u8, request_buffer[0..count], "request")) return error.UnexpectedTestMessage;
                try connection.writeMessage("head");
                if (self.mode == .small_reply) {
                    try connection.writeMessage("tail");
                } else {
                    const body: [128 * 1024]u8 = @splat(0x5a);
                    try connection.writeMessage(&body);
                }
                self.response_written.set(std.testing.io);
            },
            .read_cancel => {
                var request_buffer: [16]u8 = undefined;
                try std.testing.expectError(error.HostTimeout, ioOverlapped(connection.handle, &request_buffer, false, 20));
                self.timeout_finished.set(std.testing.io);
                const count = try connection.readMessage(&request_buffer);
                if (!std.mem.eql(u8, request_buffer[0..count], "after cancel")) return error.UnexpectedTestMessage;
                try connection.writeMessage("ack");
            },
            .write_cancel => {
                const body: [1024 * 1024]u8 = @splat(0x5a);
                try std.testing.expectError(error.HostTimeout, ioOverlapped(connection.handle, @constCast(&body), true, 20));
                connection.failed = true;
                self.timeout_finished.set(std.testing.io);
            },
        }
    }
};

test "overlapped accept cancellation releases the endpoint and slow readers receive whole replies" {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const endpoint = try testEndpoint();
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectError(error.HostTimeout, acceptTimeout(std.testing.allocator, endpoint, 20));
    var server = TransportTest{ .endpoint = endpoint, .mode = .slow_reader };
    const thread = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, TransportTest.run, .{&server});
    var joined = false;
    defer if (!joined) thread.join();
    Sleep(20); // Exercise a pending ConnectNamedPipe, not only already-connected success.
    var client = try connect(std.testing.allocator, endpoint);
    var open = true;
    defer if (open) client.deinit();
    try client.writeMessage("request");
    Sleep(30); // Server may finish its small header before the client begins reading.
    var header: [4]u8 = undefined;
    try std.testing.expectEqual(header.len, try client.readMessage(&header));
    try std.testing.expectEqualStrings("head", &header);
    var body: [128 * 1024]u8 = undefined;
    try std.testing.expectEqual(body.len, try client.readMessage(&body));
    for (body) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    client.deinit();
    open = false;
    thread.join();
    joined = true;
    try server.result;
}

test "canceled overlapped read cannot consume the next message on the same pipe" {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const endpoint = try testEndpoint();
    defer std.testing.allocator.free(endpoint);
    var server = TransportTest{ .endpoint = endpoint, .mode = .read_cancel };
    const thread = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, TransportTest.run, .{&server});
    var joined = false;
    defer if (!joined) thread.join();
    var client = try connect(std.testing.allocator, endpoint);
    var open = true;
    defer if (open) client.deinit();
    try waitTestEvent(&server.timeout_finished);
    try client.writeMessage("after cancel");
    var reply: [3]u8 = undefined;
    try std.testing.expectEqual(reply.len, try client.readMessage(&reply));
    try std.testing.expectEqualStrings("ack", &reply);
    client.deinit();
    open = false;
    thread.join();
    joined = true;
    try server.result;
}

test "server teardown preserves a fully buffered reply until its delayed reader closes" {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const endpoint = try testEndpoint();
    defer std.testing.allocator.free(endpoint);
    var server = TransportTest{ .endpoint = endpoint, .mode = .small_reply };
    const thread = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, TransportTest.run, .{&server});
    var joined = false;
    defer if (!joined) thread.join();
    var client = try connect(std.testing.allocator, endpoint);
    var open = true;
    defer if (open) client.deinit();
    try client.writeMessage("request");
    try waitTestEvent(&server.response_written);
    Sleep(30); // Both writes completed before this reader consumes either message.
    var message: [4]u8 = undefined;
    try std.testing.expectEqual(message.len, try client.readMessage(&message));
    try std.testing.expectEqualStrings("head", &message);
    try std.testing.expectEqual(message.len, try client.readMessage(&message));
    try std.testing.expectEqualStrings("tail", &message);
    client.deinit();
    open = false;
    thread.join();
    joined = true;
    try server.result;
}

test "a full pipe write timeout completes cancellation before closing its buffer" {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const endpoint = try testEndpoint();
    defer std.testing.allocator.free(endpoint);
    var server = TransportTest{ .endpoint = endpoint, .mode = .write_cancel };
    const thread = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, TransportTest.run, .{&server});
    var joined = false;
    defer if (!joined) thread.join();
    var client = try connect(std.testing.allocator, endpoint);
    defer client.deinit();
    try waitTestEvent(&server.timeout_finished);
    thread.join();
    joined = true;
    try server.result;
}
