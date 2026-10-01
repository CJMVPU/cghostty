//! Search requests never wait for the consumer to make queue space. Consecutive
//! queries replace the pending tail; navigation is an ordering barrier. Only
//! queue bookkeeping holds the mutex, never terminal access or search work.
const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Message = union(enum) {
    pub const WriteReq = @import("../../datastruct/main.zig").MessageData(u8, 255);
    change_needle: WriteReq,
    select: @import("screen.zig").ScreenSearch.Select,

    pub fn deinit(self: Message) void {
        switch (self) {
            .change_needle => |needle| needle.deinit(),
            .select => {},
        }
    }
};

const Node = struct { message: Message, next: ?*Node = null };
alloc: Allocator,
mutex: std.Io.Mutex = .init,
head: ?*Node = null,
tail: ?*Node = null,
count: usize = 0,

pub fn create(alloc: Allocator) !*Self {
    const self = try alloc.create(Self);
    self.* = .{ .alloc = alloc };
    return self;
}

/// Producers and the worker must be stopped before destruction.
pub fn destroy(self: *Self, alloc: Allocator) void {
    var next = self.head;
    while (next) |node| {
        next = node.next;
        node.message.deinit();
        self.alloc.destroy(node);
    }
    alloc.destroy(self);
}

/// Ownership transfers only on success. A failed append leaves the queue intact.
/// Query replacement needs no new node, even with a paused consumer. Navigation
/// may grow the queue; allocation failure is returned instead of waiting/dropping.
pub fn push(self: *Self, io: std.Io, message: Message) Allocator.Error!void {
    self.mutex.lockUncancelable(io);
    if (message == .change_needle) {
        if (self.tail) |tail| if (tail.message == .change_needle) {
            const old = tail.message;
            tail.message = message;
            self.mutex.unlock(io);
            old.deinit();
            return;
        };
    }
    const node = self.alloc.create(Node) catch |err| {
        self.mutex.unlock(io);
        return err;
    };
    node.* = .{ .message = message };
    if (self.tail) |tail| tail.next = node else self.head = node;
    self.tail = node;
    self.count += 1;
    self.mutex.unlock(io);
}

pub fn pop(self: *Self, io: std.Io) ?Message {
    self.mutex.lockUncancelable(io);
    const node = self.head orelse {
        self.mutex.unlock(io);
        return null;
    };
    self.head = node.next;
    if (self.head == null) self.tail = null;
    self.count -= 1;
    self.mutex.unlock(io);
    const message = node.message;
    self.alloc.destroy(node);
    return message;
}

/// Consumers use a finite budget per wakeup so new producers cannot extend an
/// in-progress drain forever and starve stop/refresh callbacks.
pub fn pendingCount(self: *Self, io: std.Io) usize {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    return self.count;
}

test "search request mailbox coalesces a paused consumer burst and preserves navigation" {
    const t = std.testing;
    const mailbox = try create(t.allocator);
    defer mailbox.destroy(t.allocator);
    for (0..10_000) |i| {
        var bytes = [_]u8{'x'} ** 512;
        bytes[0] = @intCast(i % 256);
        const message: Message = .{ .change_needle = try .init(t.allocator, @as([]const u8, &bytes)) };
        errdefer message.deinit();
        try mailbox.push(t.io, message);
    }
    try t.expectEqual(@as(usize, 1), mailbox.pendingCount(t.io));
    const last = mailbox.pop(t.io).?;
    defer last.deinit();
    try t.expectEqual(@as(u8, 9999 % 256), last.change_needle.slice()[0]);
    // More than the old capacity, with every barrier retained in order.
    for (0..200) |_| {
        try mailbox.push(t.io, .{ .change_needle = .{ .stable = "first" } });
        try mailbox.push(t.io, .{ .select = .next });
        try mailbox.push(t.io, .{ .change_needle = .{ .stable = "second" } });
        try mailbox.push(t.io, .{ .select = .prev });
    }
    try t.expectEqual(@as(usize, 800), mailbox.pendingCount(t.io));
    for (0..200) |_| {
        const first = mailbox.pop(t.io).?;
        defer first.deinit();
        try t.expectEqualStrings("first", first.change_needle.slice());
        try t.expectEqual(Message{ .select = .next }, mailbox.pop(t.io).?);
        const second = mailbox.pop(t.io).?;
        defer second.deinit();
        try t.expectEqualStrings("second", second.change_needle.slice());
        try t.expectEqual(Message{ .select = .prev }, mailbox.pop(t.io).?);
    }
    try t.expect(mailbox.pop(t.io) == null);
}

test "search request mailbox allocation failures preserve prior requests and ownership" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 2 });
    const mailbox = try create(failing.allocator());
    defer mailbox.destroy(failing.allocator());
    try mailbox.push(t.io, .{ .change_needle = .{ .stable = "old" } });
    // Replacement has no node allocation and must succeed at the failure limit.
    try mailbox.push(t.io, .{ .change_needle = .{ .stable = "new" } });
    try t.expectError(error.OutOfMemory, mailbox.push(t.io, .{ .select = .next }));
    const query = mailbox.pop(t.io).?;
    defer query.deinit();
    try t.expectEqualStrings("new", query.change_needle.slice());
    const owned: Message = .{ .change_needle = try .init(t.allocator, @as([]const u8, "long" ** 200)) };
    defer owned.deinit(); // Failed push leaves ownership with the caller.
    try t.expectError(error.OutOfMemory, mailbox.push(t.io, owned));
    try t.expectEqual(@as(usize, 0), mailbox.pendingCount(t.io));
}
