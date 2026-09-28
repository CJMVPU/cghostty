//! Presentation-only offsets. Terminal cells and protocol coordinates stay integral.
const std = @import("std");
const Journal = @import("../terminal/ScrollState.zig");
const Self = @This();
pub const capacity = 4;
pub const Region = struct {
    rect: Journal.Rect,
    /// Last submitted offset, start offset relative to the frozen image, target.
    shown: f32 = 0,
    start: f32 = 0,
    target: f32 = 0,
    /// Animation origin is independent of the frozen texture's offset.
    origin: f32 = 0,
    velocity: f32 = 0,
    began: f64 = 0,

    fn speed(self: Region, now: f64) f32 {
        const t: f32 = @floatCast(std.math.clamp((now - self.began) / duration, 0, 1));
        return (self.target - self.origin) * (6 * t * (1 - t) / duration) +
            self.velocity * ((1 - t) * (1 - 3 * t));
    }
};
regions: [capacity]Region = undefined,
len: usize = 0,
serial: u64 = 0,
epoch: u64 = 0,
viewport_serial: u64 = 0,
viewport: usize = 0,
rows: u16 = 0,
cols: u16 = 0,
alternate: bool = false,
initialized: bool = false,
/// Pose timestamps use the presentation clock, which may be ahead of update().
sampled_at: ?f64 = null,
pub const duration = 0.100;

pub fn reset(self: *Self) void {
    self.len = 0;
    self.sampled_at = null;
}
pub fn active(self: *const Self) bool {
    for (self.regions[0..self.len]) |r| if (@abs(r.shown - r.target) > 0.01) return true;
    return false;
}
/// Called once per submitted frame. True requests a new frozen image of the
/// last submitted contents. Never advances an unseen intermediate frame.
pub fn update(self: *Self, journal: Journal, viewport: usize, rows: u16, cols: u16, alternate: bool, cell_height: f32, now: f64, enabled: bool) bool {
    const valid = enabled and self.initialized and self.epoch == journal.epoch and self.rows == rows and self.cols == cols and self.alternate == alternate;
    defer {
        self.initialized = true;
        self.serial = journal.serial;
        self.epoch = journal.epoch;
        self.viewport_serial = journal.viewport_serial;
        self.viewport = viewport;
        self.rows = rows;
        self.cols = cols;
        self.alternate = alternate;
    }
    if (!valid) {
        self.reset();
        return false;
    }
    var changes: [capacity]Journal.Event = undefined;
    var count: usize = 0;
    const viewport_changed = journal.viewport_serial != self.viewport_serial;
    if (!alternate and viewport_changed and !journal.viewport_animate) {
        self.reset();
        return false;
    }
    const wheel = !alternate and viewport_changed;
    if (wheel) {
        const delta: i64 = @as(i64, @intCast(viewport)) - @as(i64, @intCast(self.viewport));
        if (@abs(delta) >= rows) {
            self.reset();
            return false;
        }
        changes[0] = .{ .rect = .{ .left = 0, .top = 0, .right = cols, .bottom = rows }, .rows = @intCast(-delta) };
        count = 1;
    } else if (alternate) {
        var serial = self.serial;
        while (serial < journal.serial) : (serial += 1) {
            const e = journal.event(serial) orelse {
                self.reset();
                return false;
            };
            var found = false;
            for (changes[0..count]) |*c| {
                if (c.rect.eql(e.rect)) {
                    c.rows += e.rows;
                    found = true;
                    break;
                }
                if (c.rect.overlaps(e.rect)) {
                    self.reset();
                    return false;
                }
            }
            if (!found) {
                if (count == capacity) {
                    self.reset();
                    return false;
                }
                changes[count] = e;
                count += 1;
            }
        }
    } else if (viewport != self.viewport) {
        self.reset();
        return false;
    }
    if (count == 0) return false;

    // Rebase the frozen texture without restarting unrelated region motion.
    // A retarget starts from a submitted pose, so its time must not precede
    // that pose's presentation timestamp (typically ahead of this callback).
    const began = @max(now, self.sampled_at orelse now);
    for (self.regions[0..self.len]) |*r| {
        r.start = r.shown;
    }
    for (changes[0..count]) |c| {
        if (@abs(c.rows) >= c.rect.bottom - c.rect.top) {
            self.reset();
            return false;
        }
        var index: usize = self.len;
        for (self.regions[0..self.len], 0..) |r, i| {
            if (r.rect.eql(c.rect)) {
                index = i;
                break;
            }
            if (r.rect.overlaps(c.rect)) {
                self.reset();
                return false;
            }
        }
        if (index == self.len) {
            if (self.len == capacity) {
                self.reset();
                return false;
            }
            self.regions[index] = .{ .rect = c.rect, .began = began };
            self.len += 1;
        }
        const r = &self.regions[index];
        const incoming = r.speed(self.sampled_at orelse now);
        r.start = r.shown - @as(f32, @floatFromInt(c.rows)) * cell_height;
        r.target = if (wheel) @as(f32, @floatCast(journal.viewport_fraction)) * cell_height else 0;
        r.origin = r.start;
        r.began = began;
        const delta = r.target - r.origin;
        // Preserve useful velocity through same-direction input. Bound the
        // Hermite tangent to keep motion monotone; reversals must not drift
        // away from the new target before turning around.
        r.velocity = if (incoming * delta > 0)
            std.math.sign(delta) * @min(@abs(incoming), 3 * @abs(delta) / duration)
        else
            0;
        if (wheel and journal.viewport_precision) r.shown = r.target else r.shown = r.start;
        if (wheel and journal.viewport_precision) {
            r.origin = r.target;
            r.velocity = 0;
        }
        // Avoid unbounded latency on a burst larger than the region.
        if (@abs(r.shown) >= @as(f32, @floatFromInt(c.rect.bottom - c.rect.top)) * cell_height) {
            self.reset();
            return false;
        }
    }
    return true;
}

pub fn sample(self: *Self, now: f64) void {
    // A changed prediction may repeat or regress, but submitted motion must
    // never run backwards solely because of the display clock.
    const timestamp = @max(now, self.sampled_at orelse now);
    self.sampled_at = timestamp;
    for (self.regions[0..self.len]) |*r| {
        if (@abs(r.shown - r.target) <= 0.01) {
            r.shown = r.target;
            continue;
        }
        const t: f32 = @floatCast(std.math.clamp((timestamp - r.began) / duration, 0, 1));
        r.shown = r.origin + (r.target - r.origin) * (t * t * (3 - 2 * t)) +
            r.velocity * (duration * t * (1 - t) * (1 - t));
        if (@abs(r.shown - r.target) < 0.01) r.shown = r.target;
    }
    // Keep stationary fractional offsets, discard completed integer motions.
    var i: usize = 0;
    while (i < self.len) {
        if (self.regions[i].shown == 0 and self.regions[i].target == 0) {
            self.len -= 1;
            self.regions[i] = self.regions[self.len];
        } else i += 1;
    }
}

test "scroll motion reverses from submitted position and respects split regions" {
    var m: Self = .{};
    var j: Journal = .{};
    _ = m.update(j, 0, 24, 80, true, 20, 0, true);
    const rect: Journal.Rect = .{ .left = 0, .top = 1, .right = 40, .bottom = 23 };
    j.record(rect, -1);
    try std.testing.expect(m.update(j, 0, 24, 80, true, 20, 0, true));
    m.sample(0.05);
    const shown = m.regions[0].shown;
    try std.testing.expect(shown > 0 and shown < 20);
    j.record(rect, 1);
    _ = m.update(j, 0, 24, 80, true, 20, 0.05, true);
    try std.testing.expectApproxEqAbs(shown - 20, m.regions[0].shown, 0.001);
    m.sample(0.2);
    try std.testing.expectEqual(@as(usize, 0), m.len);
    try std.testing.expect(!m.active());
}

test "scroll motion precision is direct and invalidation cancels" {
    var m: Self = .{};
    var j: Journal = .{};
    _ = m.update(j, 10, 24, 80, false, 20, 0, true);
    j.viewport_serial += 1;
    j.viewport_animate = true;
    j.viewport_precision = true;
    j.viewport_fraction = -0.25;
    _ = m.update(j, 9, 24, 80, false, 20, 1, true);
    try std.testing.expectEqual(@as(f32, -5), m.regions[0].shown);
    try std.testing.expect(!m.active());
    j.invalidate();
    _ = m.update(j, 9, 24, 80, false, 20, 1, true);
    try std.testing.expectEqual(@as(usize, 0), m.len);
}

test "scroll motion isolates disjoint splits and rejects overlapping operations" {
    var m: Self = .{};
    var j: Journal = .{};
    _ = m.update(j, 0, 24, 80, true, 20, 0, true);
    j.record(.{ .left = 0, .top = 1, .right = 40, .bottom = 23 }, -1);
    j.record(.{ .left = 40, .top = 1, .right = 80, .bottom = 23 }, 2);
    try std.testing.expect(m.update(j, 0, 24, 80, true, 20, 0, true));
    try std.testing.expectEqual(@as(usize, 2), m.len);
    try std.testing.expectEqual(@as(f32, 20), m.regions[0].shown);
    try std.testing.expectEqual(@as(f32, -40), m.regions[1].shown);
    j.record(.{ .left = 0, .top = 0, .right = 80, .bottom = 24 }, -1);
    try std.testing.expect(!m.update(j, 0, 24, 80, true, 20, 0, true));
    try std.testing.expectEqual(@as(usize, 0), m.len);
}

test "scroll motion catches overflow resize and large viewport jumps" {
    var m: Self = .{};
    var j: Journal = .{};
    _ = m.update(j, 0, 24, 80, true, 20, 0, true);
    for (0..Journal.capacity + 1) |_| j.record(.{ .left = 0, .top = 1, .right = 80, .bottom = 23 }, -1);
    try std.testing.expect(!m.update(j, 0, 24, 80, true, 20, 1, true));
    j.record(.{ .left = 0, .top = 1, .right = 80, .bottom = 23 }, -1);
    try std.testing.expect(m.update(j, 0, 24, 80, true, 20, 2, true));
    try std.testing.expect(!m.update(j, 0, 25, 80, true, 20, 2, true));
    try std.testing.expectEqual(@as(usize, 0), m.len);
    _ = m.update(j, 0, 24, 80, false, 20, 3, true);
    j.viewport_serial += 1;
    j.viewport_animate = true;
    try std.testing.expect(!m.update(j, 100, 24, 80, false, 20, 3, true));
}

test "scroll motion discrete wheel follows viewport direction and settles" {
    var motion: Self = .{};
    var journal: Journal = .{};
    _ = motion.update(journal, 100, 24, 80, false, 20, 0, true);
    journal.viewport_serial += 1;
    journal.viewport_animate = true;
    try std.testing.expect(motion.update(journal, 97, 24, 80, false, 20, 1, true));
    try std.testing.expectEqual(@as(f32, -60), motion.regions[0].shown);
    motion.sample(1.05);
    try std.testing.expect(motion.regions[0].shown > -60 and motion.regions[0].shown < 0);
    // Explicit scroll-to-bottom cancels the presentation offset even if
    // clamping means the integral viewport remains at the same row.
    journal.viewport_serial += 1;
    journal.viewport_animate = false;
    _ = motion.update(journal, 97, 24, 80, false, 20, 1.06, true);
    try std.testing.expectEqual(@as(usize, 0), motion.len);
    try std.testing.expect(!motion.active());
}

test "scroll motion future presentation does not skip most of a new move" {
    var motion: Self = .{};
    var journal: Journal = .{};
    _ = motion.update(journal, 100, 24, 80, false, 20, 0, true);
    journal.viewport_serial += 1;
    journal.viewport_animate = true;
    _ = motion.update(journal, 97, 24, 80, false, 20, 1, true);
    motion.sample(1.0415);
    const progress = (motion.regions[0].shown + 60) / 60;
    try std.testing.expect(progress > 0 and progress < 0.5);

    // New input is processed before the preceding frame's presentation time.
    // Retarget at that submitted pose; do not replay 41.5ms of a fresh curve.
    const before = motion.regions[0].shown;
    journal.viewport_serial += 1;
    _ = motion.update(journal, 94, 24, 80, false, 20, 1.008333, true);
    motion.sample(1.049833);
    const moved = motion.regions[0].shown - (before - 60);
    try std.testing.expect(moved > 0 and moved < 15);
    motion.sample(1.3);
    try std.testing.expect(!motion.active());
    try std.testing.expectEqual(@as(usize, 0), motion.len);
}

test "scroll motion retarget does not restart a disjoint region" {
    var motion: Self = .{};
    var journal: Journal = .{};
    _ = motion.update(journal, 0, 24, 80, true, 20, 0, true);
    const left: Journal.Rect = .{ .left = 0, .top = 1, .right = 40, .bottom = 23 };
    const right: Journal.Rect = .{ .left = 40, .top = 1, .right = 80, .bottom = 23 };
    journal.record(left, -1);
    journal.record(right, -1);
    _ = motion.update(journal, 0, 24, 80, true, 20, 1, true);
    motion.sample(1.0415);
    var uninterrupted = motion;
    journal.record(left, -1);
    _ = motion.update(journal, 0, 24, 80, true, 20, 1.008333, true);
    motion.sample(1.049833);
    uninterrupted.sample(1.049833);
    try std.testing.expectApproxEqAbs(uninterrupted.regions[1].shown, motion.regions[1].shown, 0.0001);
}

test "scroll motion repeat preserves forward speed and reversal never overshoots" {
    const t = std.testing;
    for ([_]f64{ 60, 120 }) |hz| {
        for ([_]bool{ false, true }) |alternate| {
            var motion: Self = .{};
            var journal: Journal = .{};
            var viewport: usize = 100;
            _ = motion.update(journal, viewport, 24, 80, alternate, 20, 0, true);
            var now: f64 = 1;
            const rect: Journal.Rect = .{ .left = 0, .top = 0, .right = 80, .bottom = 24 };
            for (0..12) |_| {
                const speed = if (motion.len > 0) motion.regions[0].speed(motion.sampled_at.?) else 0;
                if (alternate) journal.record(rect, -1) else {
                    viewport += 1;
                    journal.viewport_serial += 1;
                    journal.viewport_animate = true;
                }
                _ = motion.update(journal, viewport, 24, 80, alternate, 20, now, true);
                const rebased = motion.regions[0].shown;
                try t.expectApproxEqAbs(speed, motion.regions[0].speed(motion.regions[0].began), 0.001);
                motion.sample(now + 0.0415);
                try t.expect(motion.regions[0].shown < rebased);
                try t.expect(motion.regions[0].shown > 0);
                // A repeated or regressing prediction must not rewind motion.
                const shown = motion.regions[0].shown;
                motion.sample(now + 0.030);
                try t.expectEqual(shown, motion.regions[0].shown);
                now += 1 / hz;
            }
            // Move the target past the submitted pose, including any backlog
            // accumulated by one whole row of input on every 120Hz frame.
            const reverse_rows: i32 = @as(i32, @intFromFloat(@ceil(motion.regions[0].shown / 20))) + 1;
            try t.expect(reverse_rows < 24);
            if (alternate) journal.record(rect, reverse_rows) else {
                viewport -= @intCast(reverse_rows);
                journal.viewport_serial += 1;
            }
            _ = motion.update(journal, viewport, 24, 80, alternate, 20, now, true);
            const origin = motion.regions[0].shown;
            try t.expect(origin < 0);
            try t.expectEqual(@as(f32, 0), motion.regions[0].velocity);
            const began = motion.regions[0].began;
            var previous = origin;
            for (1..13) |i| {
                motion.sample(began + duration * @as(f64, @floatFromInt(i)) / 12);
                const shown = if (motion.len > 0) motion.regions[0].shown else 0;
                try t.expect(shown >= previous and shown <= 0);
                previous = shown;
            }
            try t.expect(!motion.active());
            try t.expectEqual(@as(usize, 0), motion.len);
        }
    }
}
