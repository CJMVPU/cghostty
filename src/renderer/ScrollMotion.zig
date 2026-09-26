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
    began: f64 = 0,
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
pub const duration = 0.100;

pub fn reset(self: *Self) void {
    self.len = 0;
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

    // Rebase every existing region onto the same last displayed texture.
    for (self.regions[0..self.len]) |*r| {
        r.start = r.shown;
        r.began = now;
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
            self.regions[index] = .{ .rect = c.rect, .began = now };
            self.len += 1;
        }
        const r = &self.regions[index];
        r.start = r.shown - @as(f32, @floatFromInt(c.rows)) * cell_height;
        r.target = if (wheel) @as(f32, @floatCast(journal.viewport_fraction)) * cell_height else 0;
        r.began = now;
        if (wheel and journal.viewport_precision) r.shown = r.target else r.shown = r.start;
        // Avoid unbounded latency on a burst larger than the region.
        if (@abs(r.shown) >= @as(f32, @floatFromInt(c.rect.bottom - c.rect.top)) * cell_height) {
            self.reset();
            return false;
        }
    }
    return true;
}

pub fn sample(self: *Self, now: f64) void {
    for (self.regions[0..self.len]) |*r| {
        if (@abs(r.shown - r.target) <= 0.01) {
            r.shown = r.target;
            continue;
        }
        const t: f32 = @floatCast(std.math.clamp((now - r.began) / duration, 0, 1));
        const remaining = (1 - t) * (1 - t) * (1 - t);
        r.shown = r.target + (r.start - r.target) * remaining;
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
