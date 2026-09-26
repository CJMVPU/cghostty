//! Small, allocation-free scroll journal copied with each render snapshot.
//! A missing/overwritten event makes the renderer refresh normally.
const std = @import("std");
const Self = @This();
pub const capacity = 16;
pub const Rect = struct {
    left: u16,
    top: u16,
    right: u16,
    bottom: u16,
    pub fn eql(a: Rect, b: Rect) bool {
        return std.meta.eql(a, b);
    }
    pub fn overlaps(a: Rect, b: Rect) bool {
        return a.left < b.right and b.left < a.right and a.top < b.bottom and b.top < a.bottom;
    }
};
pub const Event = struct { rect: Rect, rows: i32 };
serial: u64 = 0,
events: [capacity]Event = undefined,
/// Changes that invalidate the relationship between old and new rows.
epoch: u64 = 0,
viewport_serial: u64 = 0,
viewport_fraction: f64 = 0,
viewport_precision: bool = false,
viewport_animate: bool = false,

pub fn record(self: *Self, rect: Rect, rows: i32) void {
    self.events[self.serial % capacity] = .{ .rect = rect, .rows = rows };
    self.serial +%= 1;
}
pub fn invalidate(self: *Self) void {
    self.epoch +%= 1;
    self.viewport_fraction = 0;
}
pub fn event(self: *const Self, serial: u64) ?Event {
    if (serial >= self.serial or self.serial - serial > capacity) return null;
    return self.events[serial % capacity];
}

test "scroll journal overflow and snapshot ownership" {
    var journal: Self = .{};
    const rect: Rect = .{ .left = 0, .top = 1, .right = 20, .bottom = 9 };
    journal.record(rect, -1);
    const snapshot = journal;
    for (0..capacity) |_| journal.record(rect, 1);
    try std.testing.expect(journal.event(0) == null);
    try std.testing.expectEqual(@as(i32, -1), snapshot.event(0).?.rows);
    journal.invalidate();
    try std.testing.expectEqual(@as(u64, 1), journal.epoch);
}
