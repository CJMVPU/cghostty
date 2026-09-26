//! Latest-frame mailbox. The owner serializes all access, including applying
//! a taken frame, with its presentation mutex. Values are owned by the caller.
const std = @import("std");

pub fn Queue(comptime Value: type) type {
    return struct {
        const Self = @This();
        pub const Entry = struct { sequence: u64, value: Value };
        issued: u64 = 0,
        newest: u64 = 0,
        pending: ?Entry = null,
        scheduled: bool = false,
        closed: bool = false,

        /// Reserve before GPU submission, not in completion order.
        pub fn reserve(self: *Self) u64 {
            self.issued += 1;
            return self.issued;
        }

        pub fn offer(self: *Self, entry: Entry) struct { accepted: bool, schedule: bool = false, displaced: ?Entry = null } {
            if (self.closed or entry.sequence <= self.newest) return .{ .accepted = false };
            const old = self.pending;
            const schedule = !self.scheduled;
            self.newest = entry.sequence;
            self.pending = entry;
            self.scheduled = true;
            return .{ .accepted = true, .schedule = schedule, .displaced = old };
        }

        /// A synchronous presentation supersedes queued older frames without
        /// scheduling a second callback. The existing callback can be reused.
        pub fn supersede(self: *Self, sequence: u64) struct { accepted: bool, displaced: ?Entry = null } {
            if (self.closed or sequence <= self.newest) return .{ .accepted = false };
            self.newest = sequence;
            const old = self.pending;
            self.pending = null;
            return .{ .accepted = true, .displaced = old };
        }

        pub fn take(self: *Self) ?Entry {
            self.scheduled = false;
            const entry = self.pending;
            self.pending = null;
            return entry;
        }

        /// Reject every already-issued frame, including GPU work still running.
        pub fn invalidate(self: *Self) ?Entry {
            self.newest = self.issued;
            const entry = self.pending;
            self.pending = null;
            return entry;
        }

        pub fn close(self: *Self) ?Entry {
            self.closed = true;
            return self.invalidate();
        }
    };
}

test "PresentationQueue coalesces a stalled main queue into the newest frame" {
    const t = std.testing;
    var q: Queue(u8) = .{};
    const a = q.reserve();
    const b = q.reserve();
    const c = q.reserve();
    try t.expect(q.offer(.{ .sequence = a, .value = 1 }).schedule);
    const replacement = q.offer(.{ .sequence = c, .value = 3 });
    try t.expect(!replacement.schedule);
    try t.expectEqual(@as(u8, 1), replacement.displaced.?.value);
    try t.expect(!q.offer(.{ .sequence = b, .value = 2 }).accepted);
    try t.expectEqual(@as(u8, 3), q.take().?.value);
    try t.expect(q.take() == null);
    try t.expect(q.offer(.{ .sequence = q.reserve(), .value = 4 }).schedule);
}

test "PresentationQueue sync redraw prevents same-size stale frames and reuses queued callback" {
    const t = std.testing;
    var q: Queue(u8) = .{};
    const a = q.reserve();
    const b = q.reserve();
    _ = q.offer(.{ .sequence = a, .value = 1 });
    try t.expectEqual(@as(u8, 1), q.supersede(b).displaced.?.value);
    try t.expect(!q.offer(.{ .sequence = a, .value = 1 }).accepted);
    try t.expect(q.pending == null);
    const c = q.reserve();
    try t.expect(!q.offer(.{ .sequence = c, .value = 3 }).schedule);
    try t.expectEqual(@as(u8, 3), q.take().?.value);
    try t.expect(!q.supersede(b).accepted);
}

test "PresentationQueue hiding rejects in-flight frames and close drains queued work" {
    const t = std.testing;
    var q: Queue(u8) = .{};
    const a = q.reserve();
    const in_flight = q.reserve();
    _ = q.offer(.{ .sequence = a, .value = 1 });
    try t.expectEqual(@as(u8, 1), q.invalidate().?.value);
    try t.expect(!q.offer(.{ .sequence = in_flight, .value = 2 }).accepted);
    try t.expect(!q.offer(.{ .sequence = q.reserve(), .value = 3 }).schedule);
    try t.expectEqual(@as(u8, 3), q.close().?.value);
    try t.expect(q.take() == null);
    try t.expect(!q.offer(.{ .sequence = q.reserve(), .value = 4 }).accepted);
    try t.expect(!q.supersede(q.reserve()).accepted);
}
