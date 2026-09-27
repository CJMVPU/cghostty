//! Worker timers only advance image content. Window display callbacks own motion.
const std = @import("std");

/// Avoid a zero-delay timer loop when an image deadline is already overdue.
pub const minimum_delay_ms: u64 = 8;
pub const Wake = struct { delay_ms: u64 };

pub fn nextWake(now_ms: u64, kitty_deadline_ms: u64) Wake {
    return .{ .delay_ms = @max(kitty_deadline_ms -| now_ms, minimum_delay_ms) };
}

/// Frequent terminal input must not postpone an already scheduled image frame.
pub const Timer = struct {
    pending: ?u64 = null,
    pub const Action = union(enum) { keep, cancel, arm: Wake };

    pub fn request(self: *Timer, now_ms: u64, wake: ?Wake) Action {
        const next = wake orelse {
            const had_pending = self.pending != null;
            self.pending = null;
            return if (had_pending) .cancel else .keep;
        };
        const deadline = now_ms +| next.delay_ms;
        if (self.pending) |previous| {
            if (previous <= deadline) return .keep;
        }
        self.pending = deadline;
        return .{ .arm = next };
    }

    pub fn fired(self: *Timer) bool {
        const pending = self.pending != null;
        self.pending = null;
        return pending;
    }
};

test "FrameScheduler continuous input preserves the image deadline" {
    const t = std.testing;
    var timer: Timer = .{};
    try t.expect(timer.request(0, nextWake(0, 40)) == .arm);
    for (1..32) |now| try t.expect(timer.request(now, nextWake(now, 40)) == .keep);
    try t.expectEqual(@as(?u64, 40), timer.pending);
    try t.expect(timer.fired());
    try t.expect(!timer.fired());
    try t.expectEqual(minimum_delay_ms, nextWake(100, 40).delay_ms);
}

test "FrameScheduler hidden or completed images cancel and resume" {
    const t = std.testing;
    var timer: Timer = .{};
    _ = timer.request(0, nextWake(0, 40));
    try t.expect(timer.request(1, null) == .cancel);
    try t.expect(!timer.fired());
    try t.expect(timer.request(2, null) == .keep);
    try t.expect(timer.request(100, nextWake(100, 150)) == .arm);
    try t.expect(timer.request(110, nextWake(110, 130)) == .arm);
    try t.expectEqual(@as(?u64, 130), timer.pending);
}
