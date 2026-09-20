//! Pure frame scheduling policy. Thread timers and DisplayLink lifecycle stay
//! with their existing owners; this module never takes locks or reads a clock.
const std = @import("std");

/// Minimum delay for animation wakes (approximately 120 Hz).
pub const draw_interval_ms: u64 = 8;

pub const Wake = struct {
    delay_ms: u64,
    kind: Kind,

    pub const Kind = enum {
        /// Motion only: sample geometry and draw without rebuilding cells.
        draw,
        /// Animated image data must advance before drawing.
        update,
    };
};

/// Kitty deadlines are absolute on the caller's animation clock. Repeated
/// cursor draws must never postpone an image's next frame.
pub fn nextWake(now_ms: u64, cursor_active: bool, kitty_deadline_ms: ?u64) ?Wake {
    if (kitty_deadline_ms) |deadline| {
        const delay = @max(deadline -| now_ms, draw_interval_ms);
        // Updating includes drawing, so it wins a tie with cursor motion.
        if (!cursor_active or delay <= draw_interval_ms) {
            return .{ .delay_ms = delay, .kind = .update };
        }
    }
    if (cursor_active) return .{ .delay_ms = draw_interval_ms, .kind = .draw };
    return null;
}

pub fn needsDisplayLink(visible: bool, cells_rebuilt: bool, wake: ?Wake) bool {
    return visible and (cells_rebuilt or wake != null);
}

test "FrameScheduler idle and completed motion stop requesting frames" {
    const testing = std.testing;
    try testing.expectEqual(@as(?Wake, null), nextWake(100, false, null));
    const moving = nextWake(100, true, null).?;
    try testing.expectEqual(Wake.Kind.draw, moving.kind);
    try testing.expectEqual(draw_interval_ms, moving.delay_ms);
    try testing.expect(!needsDisplayLink(true, false, nextWake(108, false, null)));
}

test "FrameScheduler continuous cursor draws do not starve image updates" {
    const testing = std.testing;
    // A 40 ms image frame becomes due even while cursor input keeps arriving.
    for (0..4) |frame| {
        const wake = nextWake(frame * 8, true, 40).?;
        try testing.expectEqual(Wake.Kind.draw, wake.kind);
        try testing.expectEqual(draw_interval_ms, wake.delay_ms);
    }
    const due = nextWake(32, true, 40).?;
    try testing.expectEqual(Wake.Kind.update, due.kind);
    try testing.expectEqual(draw_interval_ms, due.delay_ms);
}

test "FrameScheduler image deadlines retain remaining time without motion" {
    const testing = std.testing;
    const first = nextWake(10, false, 80).?;
    const later = nextWake(30, false, 80).?;
    try testing.expectEqual(Wake.Kind.update, first.kind);
    try testing.expectEqual(@as(u64, 70), first.delay_ms);
    try testing.expectEqual(@as(u64, 50), later.delay_ms);
    // No unsigned underflow or zero-delay spin for an overdue frame.
    try testing.expectEqual(draw_interval_ms, nextWake(100, false, 80).?.delay_ms);
}

test "FrameScheduler visibility gates display link and resumes pending work" {
    const testing = std.testing;
    const wake = nextWake(0, true, 40);
    try testing.expect(!needsDisplayLink(false, true, wake));
    try testing.expect(needsDisplayLink(true, false, wake));
    try testing.expect(needsDisplayLink(true, true, null));
    try testing.expect(!needsDisplayLink(true, false, null));
}
