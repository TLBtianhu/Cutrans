//! Incarnation-local retry bookkeeping. Domain policies (epoch, CAS and the
//! actual operation) stay with their owner; this mechanism never evicts client
//! high-water marks and reserves all memory before effects may begin.
const std = @import("std");

pub fn Book(comptime Outcome: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Receipt = struct { client: [2]u64, sequence: u64, digest: [32]u8, outcome: Outcome };
        pub const Refusal = enum { conflict, expired, bad_sequence, client_limit };
        pub const Decision = union(enum) { replayed: Outcome, refused: Refusal, ready: *u64 };

        clients: std.AutoHashMap([2]u64, u64),
        client_limit: usize,
        receipts: [capacity]Receipt = undefined,
        count: usize = 0,
        next: usize = 0,

        pub fn init(allocator: std.mem.Allocator, client_limit: usize) Self {
            return .{ .clients = std.AutoHashMap([2]u64, u64).init(allocator), .client_limit = client_limit };
        }

        pub fn deinit(self: *Self) void {
            self.clients.deinit();
        }

        /// Seed a client's persistent high-water mark after a Runtime restart.
        /// The receipt ring may have evicted the original outcome, but a sequence
        /// at or below this mark must never execute again.
        pub fn seed(self: *Self, client: [2]u64, high: u64) !void {
            if (self.clients.get(client)) |existing| {
                if (existing < high) try self.clients.put(client, high);
                return;
            }
            if (self.clients.count() >= self.client_limit) return;
            try self.clients.put(client, high);
        }

        /// Caller checks nonzero client/sequence and Runtime epoch first, and
        /// serializes prepare/effect/record. No other prepare may invalidate the
        /// ready pointer before record; operation errors still need a receipt.
        pub fn prepare(self: *Self, client: [2]u64, sequence: u64, digest: [32]u8) !Decision {
            if (self.clients.get(client)) |high| {
                if (sequence <= high) {
                    for (self.receipts[0..self.count]) |receipt| {
                        if (receipt.client[0] != client[0] or receipt.client[1] != client[1] or receipt.sequence != sequence) continue;
                        if (!std.mem.eql(u8, &receipt.digest, &digest)) return .{ .refused = .conflict };
                        return .{ .replayed = receipt.outcome };
                    }
                    return .{ .refused = .expired };
                }
                if (high == std.math.maxInt(u64) or sequence != high + 1) return .{ .refused = .bad_sequence };
            } else {
                if (sequence != 1) return .{ .refused = .bad_sequence };
                if (self.clients.count() >= self.client_limit) return .{ .refused = .client_limit };
            }
            const entry = try self.clients.getOrPut(client);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            return .{ .ready = entry.value_ptr };
        }

        pub fn record(self: *Self, high: *u64, client: [2]u64, sequence: u64, digest: [32]u8, outcome: Outcome) void {
            high.* = sequence;
            self.receipts[self.next] = .{ .client = client, .sequence = sequence, .digest = digest, .outcome = outcome };
            self.next = (self.next + 1) % self.receipts.len;
            self.count = @min(self.count + 1, self.receipts.len);
        }
    };
}

pub fn hashNumber(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

test "a seeded persistent high-water refuses evicted sequences" {
    const T = Book(u64, 1);
    const digest: [32]u8 = @splat(1);
    const client = [2]u64{ 9, 10 };
    var book = T.init(std.testing.allocator, 1);
    defer book.deinit();
    try book.seed(client, 7);
    try std.testing.expectEqual(T.Refusal.expired, (try book.prepare(client, 7, digest)).refused);
    try std.testing.expectEqual(T.Refusal.bad_sequence, (try book.prepare(client, 9, digest)).refused);
    const ready = (try book.prepare(client, 8, digest)).ready;
    book.record(ready, client, 8, digest, 80);
    try std.testing.expectEqual(@as(u64, 80), (try book.prepare(client, 8, digest)).replayed);
}

test "bounded receipts retain client high-water and fail before effects on allocation" {
    const T = Book(u64, 2);
    const digest: [32]u8 = @splat(1);
    const client = [2]u64{ 1, 2 };
    var book = T.init(std.testing.allocator, 1);
    defer book.deinit();
    for (1..4) |seq| {
        const ready = (try book.prepare(client, seq, digest)).ready;
        book.record(ready, client, seq, digest, seq * 10);
    }
    try std.testing.expectEqual(T.Refusal.expired, (try book.prepare(client, 1, digest)).refused);
    try std.testing.expectEqual(@as(u64, 30), (try book.prepare(client, 3, digest)).replayed);
    try std.testing.expectEqual(T.Refusal.conflict, (try book.prepare(client, 3, @splat(2))).refused);
    try std.testing.expectEqual(T.Refusal.bad_sequence, (try book.prepare(client, 5, digest)).refused);
    try std.testing.expectEqual(T.Refusal.client_limit, (try book.prepare(.{ 3, 4 }, 1, digest)).refused);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var unavailable = T.init(failing.allocator(), 1);
    defer unavailable.deinit();
    try std.testing.expectError(error.OutOfMemory, unavailable.prepare(client, 1, digest));
    try std.testing.expectEqual(@as(usize, 0), unavailable.clients.count());
}
