//! A stable cursor body with a trail of previously submitted draw positions.
//! Shape follows an input burst independently of each positional retarget.
const Self = @This();
const std = @import("std");
const Trail = @import("CursorTrail.zig");
pub const Vec = @Vector(2, f32);
pub const Shape = enum { block, bar, underline };

pub const expansion: f32 = 0.12;
pub const history_capacity = 32;
const HistoryPoint = struct { time: f64, center: Vec };
const attack: f32 = 0.024;
const minimum_duration: f32 = 0.024;
const maximum_duration: f32 = 0.220;
// Bridge ordinary key-repeat gaps instead of closing on every cell arrival.
const burst_hold: f32 = 0.120;
const release: f32 = 0.100;

pub const Sample = struct {
    center: Vec,
    trail: [history_capacity]Vec = .{@as(Vec, @splat(0))} ** history_capacity,
    trail_len: u32 = 0,
    trail_radii: [history_capacity]f32 = .{0} ** history_capacity,
    size: Vec,
    roundness: f32 = 0,
};

initialized: bool = false,
running: bool = false,
hidden: bool = false,
origin: Vec = @splat(0),
history: [history_capacity]HistoryPoint = undefined,
history_len: usize = 0,
velocity_from: Vec = @splat(0),
target: Vec = @splat(0),
size: Vec = @splat(0),
shape: Shape = .block,
began: f64 = 0,
duration: f32 = 0,
shape_from: f32 = 0,
shape_began: f64 = 0,
hold_until: f64 = 0,

fn length(v: Vec) f32 {
    return @sqrt(@reduce(.Add, v * v));
}

/// Fast response from the displayed center; zero arrival slope, no overshoot.
pub fn progress(t_: f32) f32 {
    const t = std.math.clamp(t_, 0, 1);
    const remaining = 1 - t;
    return 1 - remaining * remaining * remaining;
}

pub fn timing(delta: Vec, width: f32) f32 {
    const distance = length(delta) / @max(width, 1);
    const x = std.math.clamp((distance - 1) / 7, 0, 1);
    return minimum_duration + (maximum_duration - minimum_duration) * x * x * (3 - 2 * x);
}

fn durationWeight(duration: f32) f32 {
    return std.math.clamp((duration - minimum_duration) / (maximum_duration - minimum_duration), 0, 1);
}

fn tailLag(duration: f32) f32 {
    return 0.040 + 0.020 * durationWeight(duration);
}

/// Hermite interpolation preserves the initial velocity and stops exactly at
/// the deadline. Resting short moves use the original ease-out initial slope;
/// resting long moves start at zero velocity, preserving the gradual onset.
pub fn velocity(self: *const Self, now: f64) Vec {
    if (!self.running or self.duration <= 0 or now >= self.began + self.duration) return @splat(0);
    const t = std.math.clamp(@as(f32, @floatCast(now - self.began)) / self.duration, 0, 1);
    return (self.target - self.origin) * @as(Vec, @splat(6 * t * (1 - t) / self.duration)) +
        self.velocity_from * @as(Vec, @splat((1 - t) * (1 - 3 * t)));
}

fn boundedVelocity(incoming: Vec, delta: Vec, duration: f32, width: f32) Vec {
    const distance = length(delta);
    if (distance < 0.001) return @splat(0);
    const direction = delta / @as(Vec, @splat(distance));
    const forward = @reduce(.Add, incoming * direction);
    // Strong reversals discard old inertia instead of initially moving away.
    if (forward < -0.5 * length(incoming)) return @splat(0);
    var lateral = incoming - direction * @as(Vec, @splat(forward));
    // max(t*(1-t)^2) = 4/27: keep turn bowing within a quarter cell.
    const lateral_limit = 27.0 / 4.0 * 0.25 * @max(width, 1) / duration;
    const lateral_speed = length(lateral);
    if (lateral_speed > lateral_limit) lateral *= @as(Vec, @splat(lateral_limit / lateral_speed));
    // A scalar Hermite tangent in [0, 3*distance] cannot overshoot.
    return direction * @as(Vec, @splat(std.math.clamp(forward, 0, 3 * distance / duration))) + lateral;
}

fn amount(self: *const Self, now: f64) f32 {
    if (!self.running) return 0;
    if (now <= self.hold_until) {
        const elapsed: f32 = @floatCast(@max(0, now - self.shape_began));
        return self.shape_from + (1 - self.shape_from) * progress(elapsed / attack);
    }
    // The hold always outlasts attack, so release starts from exactly one.
    const t = std.math.clamp(@as(f32, @floatCast(now - self.hold_until)) / release, 0, 1);
    const ease = t * t * (3 - 2 * t);
    return 1 - ease;
}

pub fn sample(self: *const Self, now: f64) Sample {
    var pose: Sample = .{ .center = self.target, .size = self.size };
    if (self.running and now < self.hold_until + release) {
        const elapsed: f32 = @floatCast(@max(0, now - self.began));
        const t = std.math.clamp(elapsed / self.duration, 0, 1);
        const deform = self.amount(now);
        pose.center = self.origin + (self.target - self.origin) * @as(Vec, @splat(t * t * (3 - 2 * t))) +
            self.velocity_from * @as(Vec, @splat(self.duration * t * (1 - t) * (1 - t)));
        pose.size = self.size * @as(Vec, @splat(1 + expansion * deform));
        pose.roundness = deform;
    }
    if (self.history_len == 0) return pose;

    // Always include the last submitted body, even after a slow/missed frame.
    // Older points preserve turns instead of cutting across their chord.
    const cutoff = @min(now - tailLag(self.duration), self.history[self.history_len - 1].time);
    var i = self.history_len;
    var previous = pose.center;
    while (i > 0) {
        i -= 1;
        const point = self.history[i];
        var center = point.center;
        if (point.time < cutoff and i + 1 < self.history_len) {
            const next = self.history[i + 1];
            const t: f32 = @floatCast((cutoff - point.time) / (next.time - point.time));
            center += (next.center - center) * @as(Vec, @splat(t));
        }
        if (length(center - previous) > 0.001) {
            pose.trail[pose.trail_len] = center - pose.center;
            pose.trail_len += 1;
            previous = center;
        }
        if (point.time <= cutoff) break;
    }
    pose.trail_len = Trail.compact(pose.trail[0..pose.trail_len], pose.trail_radii[0..pose.trail_len]);
    return pose;
}

/// Record only after the frame has been encoded and submitted. Sampling,
/// target changes and aborted draw attempts must not invent visible history.
pub fn recordFrame(self: *Self, now: f64, pose: Sample) void {
    if (!self.initialized or self.hidden) return;
    if (self.history_len > 0 and now <= self.history[self.history_len - 1].time) return;
    if (self.running and @reduce(.And, pose.center == self.target) and
        self.history_len > 0 and @reduce(.Or, self.history[self.history_len - 1].center != self.target))
    {
        // Drain from the frame that actually reached the target, not the
        // ideal arrival time between two display refreshes.
        self.hold_until = @max(self.hold_until, now + tailLag(self.duration));
    }
    const cutoff = now - tailLag(self.duration);
    while (self.history_len > 1 and self.history[1].time <= cutoff) {
        std.mem.copyForwards(HistoryPoint, self.history[0 .. self.history_len - 1], self.history[1..self.history_len]);
        self.history_len -= 1;
    }
    // Keep the first stationary point to let the moving history expire;
    // only coalesce subsequent stationary frames.
    if (self.history_len >= 2 and
        @reduce(.And, self.history[self.history_len - 1].center == pose.center) and
        @reduce(.And, self.history[self.history_len - 2].center == pose.center))
    {
        self.history[self.history_len - 1].time = now;
        return;
    }
    if (self.history_len == history_capacity) {
        std.mem.copyForwards(HistoryPoint, self.history[0 .. history_capacity - 1], self.history[1..]);
        self.history_len -= 1;
    }
    self.history[self.history_len] = .{ .time = now, .center = pose.center };
    self.history_len += 1;
}

pub fn reset(self: *Self) void {
    self.* = .{};
}

/// Terminal redraw/blink suppresses drawing without discarding motion.
pub fn hide(self: *Self) void {
    self.hidden = true;
}

pub fn update(self: *Self, target: Vec, size: Vec, timing_width: f32, now: f64, shape: Shape) Sample {
    self.hidden = false;
    if (!self.initialized or shape != self.shape or @reduce(.Or, size != self.size)) {
        self.* = .{ .initialized = true, .origin = target, .target = target, .size = size, .shape = shape };
        return self.sample(now);
    }
    if (length(target - self.target) >= 0.5) {
        const displayed = self.sample(now);
        const duration = timing(target - self.target, timing_width);
        const in_flight = self.running and now < self.began + self.duration;
        const incoming = self.velocity(now);
        // Continue an opening/held shape without restarting its envelope.
        // If a new burst interrupts release, open from the displayed amount.
        if (!self.running or now > self.hold_until) {
            self.shape_from = displayed.roundness;
            self.shape_began = now;
        }
        self.origin = displayed.center;
        self.velocity_from = if (in_flight)
            boundedVelocity(incoming, target - displayed.center, duration, timing_width)
        else
            (target - displayed.center) * @as(Vec, @splat(3 * (1 - durationWeight(duration)) / duration));
        self.target = target;
        self.began = now;
        self.duration = duration;
        self.hold_until = now + @max(duration + tailLag(duration), burst_hold);
        self.running = true;
    }
    if (now >= self.hold_until + release) {
        // If no frame was submitted during a long stall, connect the final
        // body to the last visible position and allow that trail to drain.
        if (self.history_len > 0 and length(self.history[self.history_len - 1].center - target) > 0.001) {
            self.hold_until = now + tailLag(self.duration);
            self.running = true;
        } else self.running = false;
    }
    return self.sample(now);
}

/// Blend the final subpixel rounding into the exact native glyph.
pub fn effect(self: *const Self, now: f64) f32 {
    if (!self.running or self.hidden) return 0;
    if (now <= self.hold_until) return 1;
    return std.math.clamp(self.amount(now) / 0.02, 0, 1);
}

test "SmoothCursor distance timing and monotone center response" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f32, 0.024), timing(.{ 10, 0 }, 10), 0.000001);
    try t.expectApproxEqAbs(@as(f32, 0.220), timing(.{ 80, 0 }, 10), 0.000001);
    try t.expectApproxEqAbs(@as(f32, 0.064), timing(.{ 10, 0 }, 10) + tailLag(timing(.{ 10, 0 }, 10)), 0.000001);
    try t.expectApproxEqAbs(@as(f32, 0.280), timing(.{ 80, 0 }, 10) + tailLag(timing(.{ 80, 0 }, 10)), 0.000001);
    try t.expectEqual(timing(.{ 30, 40 }, 10), timing(.{ 0, 50 }, 10));
    var previous: f32 = 0;
    for (0..1001) |i| {
        const p = progress(@as(f32, @floatFromInt(i)) / 1000);
        try t.expect(p >= previous and p <= 1);
        previous = p;
    }
}

fn expectUniform(pose: Sample, native: Vec) !void {
    const t = std.testing;
    const scale = pose.size / native;
    try t.expect(scale[0] >= 1 and scale[0] <= 1.120001);
    try t.expectApproxEqAbs(scale[0], scale[1], 0.000001);
    for (pose.trail[0..pose.trail_len]) |offset| try t.expect(std.math.isFinite(offset[0]) and std.math.isFinite(offset[1]));
    try t.expect(pose.roundness >= 0 and pose.roundness <= 1);
    try t.expect(std.math.isFinite(pose.center[0]) and std.math.isFinite(pose.center[1]));
}

test "SmoothCursor every frame preserves aspect ratio and twelve percent bounds in eight directions" {
    for ([_]Vec{ .{ 10, 0 }, .{ -10, 0 }, .{ 0, 20 }, .{ 0, -20 }, .{ 10, 20 }, .{ -10, 20 }, .{ -10, -20 }, .{ 10, -20 } }) |step| {
        for ([_]struct { size: Vec, shape: Shape }{
            .{ .size = .{ 10, 20 }, .shape = .block },
            .{ .size = .{ 3, 20 }, .shape = .bar },
            .{ .size = .{ 10, 2 }, .shape = .underline },
        }) |cursor| {
            var s: Self = .{};
            _ = s.update(.{ 0, 0 }, cursor.size, 10, 0, cursor.shape);
            _ = s.update(step, cursor.size, 10, 1, cursor.shape);
            for (0..301) |ms| {
                const now = 1 + @as(f64, @floatFromInt(ms)) / 1000;
                const p = s.sample(now);
                try expectUniform(p, cursor.size);
                inline for (0..2) |axis| try std.testing.expect(p.center[axis] >= @min(0, step[axis]) and p.center[axis] <= @max(0, step[axis]));
                if (ms >= 24 and ms <= 119) try std.testing.expectApproxEqAbs(@as(f32, 1.12), p.size[0] / cursor.size[0], 0.000001);
            }
            const final = s.update(step, cursor.size, 10, 2, cursor.shape);
            try std.testing.expectEqual(Sample{ .center = step, .size = cursor.size }, final);
            try std.testing.expect(!s.running and s.effect(2) == 0);
        }
    }
}

test "SmoothCursor sustained one-cell input keeps scale across slow repeat gaps and reversals" {
    for ([_]f64{ 0.008, 0.016, 0.033, 0.060, 0.100 }) |interval| {
        for ([_]Vec{ .{ 10, 0 }, .{ -10, 0 }, .{ 0, 20 }, .{ 0, -20 }, .{ 10, 20 } }) |step| {
            var s: Self = .{};
            _ = s.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0, .block);
            for (1..201) |i| {
                const now = @as(f64, @floatFromInt(i)) * interval;
                const before = s.sample(now);
                // Reverse repeatedly, including before the previous move ends.
                const target = step * @as(Vec, @splat(@floatFromInt(@min(i % 40, 40 - i % 40))));
                const after = s.update(target, s.size, 10, now, .block);
                try std.testing.expectEqual(before, after);
                for (0..100) |frame| {
                    const pose = s.sample(now + interval * @as(f64, @floatFromInt(frame)) / 100);
                    try expectUniform(pose, s.size);
                    if (i > 10) try std.testing.expectApproxEqAbs(@as(f32, 1.12), pose.size[0] / s.size[0], 0.000001);
                }
            }
            _ = s.update(s.target, s.size, 10, s.began + 1, .block);
            try std.testing.expect(!s.running);
        }
    }
}

test "SmoothCursor release and interrupted release are continuous and settle exactly" {
    var s: Self = .{};
    _ = s.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0, .block);
    _ = s.update(.{ 10, 0 }, s.size, 10, 1, .block);
    var previous: f32 = 1.12;
    for (0..101) |ms| {
        const now = s.hold_until + @as(f64, @floatFromInt(ms)) / 1000;
        const pose = s.sample(now);
        try expectUniform(pose, s.size);
        const scale = pose.size[0] / s.size[0];
        try std.testing.expect(scale <= previous + 0.000001);
        previous = scale;
    }
    const before = s.sample(1.16);
    const after = s.update(.{ -10, 20 }, s.size, 10, 1.16, .block);
    try std.testing.expectEqual(before, after);
    for (0..241) |ms| try expectUniform(s.sample(1.16 + @as(f64, @floatFromInt(ms)) / 1000), s.size);
    try std.testing.expectEqual(Sample{ .center = s.target, .size = s.size }, s.update(s.target, s.size, 10, 2, .block));
}

test "SmoothCursor Vim redraws preserve motion and shape switches use the new native size" {
    const matches = [_]Vec{ .{ 30, 40 }, .{ 400, 40 }, .{ 150, 240 }, .{ 600, 100 }, .{ 10, 360 } };
    var s: Self = .{};
    _ = s.update(matches[0], .{ 10, 20 }, 10, 0, .block);
    for (1..201) |i| {
        const now = @as(f64, @floatFromInt(i)) * 0.016;
        s.hide();
        try std.testing.expectEqual(@as(f32, 0), s.effect(now));
        const before = s.sample(now);
        try std.testing.expectEqual(before, s.update(matches[i % matches.len], s.size, 10, now, .block));
        try std.testing.expect(s.running and s.effect(now) > 0);
        try expectUniform(s.sample(now + 0.008), s.size);
    }
    const bar = s.update(s.target, .{ 3, 20 }, 10, 4, .bar);
    try std.testing.expectEqual(@as(Vec, .{ 3, 20 }), bar.size);
    try std.testing.expect(!s.running);
    _ = s.update(s.target + @as(Vec, .{ 10, 0 }), s.size, 10, 5, .bar);
    try std.testing.expectApproxEqAbs(@as(f32, 3.36), s.sample(5.03).size[0], 0.000001);
    const resized = s.update(s.target, .{ 3, 30 }, 15, 5.04, .bar);
    try std.testing.expectEqual(@as(Vec, .{ 3, 30 }), resized.size);
    try std.testing.expect(!s.running);
    s.reset();
    try std.testing.expect(!s.initialized);
}

test "SmoothCursor long onset accelerates while one-cell input stays fast" {
    const t = std.testing;
    var short: Self = .{};
    _ = short.update(.{ 0, 0 }, .{ 19, 42 }, 19, 0, .block);
    _ = short.update(.{ 19, 0 }, short.size, 19, 1, .block);
    try t.expectApproxEqAbs(19 * progress((1.0 / 60.0) / minimum_duration), short.sample(1 + 1.0 / 60.0).center[0], 0.0001);
    for ([_]Vec{ .{ 1000, 0 }, .{ 0, 1000 }, .{ 600, 800 } }) |step| {
        var s: Self = .{};
        _ = s.update(.{ 0, 0 }, .{ 19, 42 }, 19, 0, .block);
        _ = s.update(step, s.size, 19, 1, .block);
        try t.expect(length(s.sample(1 + 1.0 / 60.0).center) < 17);
        try t.expect(length(s.sample(1 + 1.0 / 120.0).center) < 5);
        try t.expectEqual(step, s.sample(1.221).center);
    }
}

test "SmoothCursor consecutive submitted frames overlap in eight directions at multiple refresh rates" {
    const t = std.testing;
    for ([_]f64{ 30, 60, 120, 240 }) |hz| {
        for ([_]Vec{ .{ 1000, 0 }, .{ -1000, 0 }, .{ 0, 1000 }, .{ 0, -1000 }, .{ 600, 800 }, .{ -600, 800 }, .{ 600, -800 }, .{ -600, -800 } }) |step| {
            for ([_]struct { size: Vec, shape: Shape }{
                .{ .size = .{ 19, 42 }, .shape = .block },
                .{ .size = .{ 3, 42 }, .shape = .bar },
                .{ .size = .{ 19, 3 }, .shape = .underline },
            }) |cursor| {
                var s: Self = .{};
                var previous = s.update(.{ 0, 0 }, cursor.size, 19, 0, cursor.shape);
                s.recordFrame(0, previous);
                previous = s.update(step, cursor.size, 19, 1, cursor.shape);
                s.recordFrame(1, previous);
                for (1..@as(usize, @intFromFloat(hz / 2))) |i| {
                    const now = 1 + @as(f64, @floatFromInt(i)) / hz;
                    const pose = s.update(step, cursor.size, 19, now, cursor.shape);
                    try expectUniform(pose, cursor.size);
                    if (length(pose.center - previous.center) > 0.001) {
                        try t.expect(pose.trail_len > 0);
                        // The first segment ends INSIDE the previous body,
                        // not merely near its predicted current position.
                        try t.expect(length(pose.center + pose.trail[0] - previous.center) < 0.001);
                    }
                    s.recordFrame(now, pose);
                    previous = pose;
                    if (now >= 1.3) try t.expectEqual(@as(u32, 0), pose.trail_len);
                }
                try t.expect(!s.running);
            }
        }
    }
}

test "SmoothCursor history retains submitted turns and ignores speculative or aborted frames" {
    const t = std.testing;
    var s: Self = .{};
    const initial = s.update(.{ 0, 0 }, .{ 19, 42 }, 19, 0, .block);
    s.recordFrame(0, initial);
    s.recordFrame(1, s.update(.{ 1000, 0 }, s.size, 19, 1, .block));
    const first = s.update(s.target, s.size, 19, 1.016, .block);
    s.recordFrame(1.016, first);
    const submitted_count = s.history_len;
    // An attempted draw computes a different position but is not submitted.
    _ = s.update(s.target, s.size, 19, 1.024, .block);
    try t.expectEqual(submitted_count, s.history_len);
    const changed = s.update(.{ 1000, 1000 }, s.size, 19, 1.032, .block);
    try t.expect(length(changed.center + changed.trail[0] - first.center) < 0.001);
    s.recordFrame(1.032, changed);
    const turned = s.update(s.target, s.size, 19, 1.048, .block);
    try t.expect(turned.trail_len >= 2);
    try t.expect(length(turned.center + turned.trail[0] - changed.center) < 0.001);
    // Straight older samples may collapse, but the previous-frame endpoint
    // above must survive, along with the earlier end of the path.
    try t.expect(length(turned.trail[turned.trail_len - 1]) > length(turned.trail[0]));
    // Changing cursor geometry cannot reuse the previous shape's trail.
    const bar = s.update(s.target, .{ 3, 42 }, 19, 1.049, .bar);
    try t.expectEqual(@as(u32, 0), bar.trail_len);
    try t.expectEqual(@as(usize, 0), s.history_len);
}

test "SmoothCursor stalled rendering bridges the last submitted body then drains" {
    const t = std.testing;
    var s: Self = .{};
    s.recordFrame(0, s.update(.{ 0, 0 }, .{ 19, 42 }, 19, 0, .block));
    s.recordFrame(1, s.update(.{ 1000, 0 }, s.size, 19, 1, .block));
    const late = s.update(s.target, s.size, 19, 1.5, .block);
    try t.expectEqual(@as(Vec, .{ 1000, 0 }), late.center);
    try t.expectEqual(@as(Vec, .{ -1000, 0 }), late.trail[0]);
    try t.expectEqual(@as(f32, 1), s.effect(1.5));
    s.recordFrame(1.5, late);
    for (1..101) |i| {
        const now = 1.5 + @as(f64, @floatFromInt(i)) / 1000;
        const pose = s.update(s.target, s.size, 19, now, .block);
        s.recordFrame(now, pose);
        if (i > 61) try t.expectEqual(@as(u32, 0), pose.trail_len);
    }
    _ = s.update(s.target, s.size, 19, 2, .block);
    try t.expect(!s.running);
}

test "SmoothCursor rapid repeated jumps retain previous submitted positions with bounded history storage" {
    const t = std.testing;
    for ([_]f64{ 0.001, 0.008, 0.016, 0.033, 0.100 }) |interval| {
        var s: Self = .{};
        var previous = s.update(.{ 0, 0 }, .{ 19, 42 }, 19, 0, .block);
        s.recordFrame(0, previous);
        const targets = [_]Vec{ .{ 1800, 0 }, .{ 1800, 900 }, .{ 0, 900 }, .{ 0, 0 } };
        for (1..501) |i| {
            const now = @as(f64, @floatFromInt(i)) * interval;
            const pose = s.update(targets[i % targets.len], s.size, 19, now, .block);
            try expectUniform(pose, s.size);
            if (length(pose.center - previous.center) > 0.001) {
                try t.expect(pose.trail_len > 0);
                try t.expect(length(pose.center + pose.trail[0] - previous.center) < 0.001);
            }
            try t.expect(s.history_len <= history_capacity);
            s.recordFrame(now, pose);
            previous = pose;
        }
        var now = s.began;
        for (0..100) |_| {
            now += 0.01;
            const pose = s.update(s.target, s.size, 19, now, .block);
            s.recordFrame(now, pose);
        }
        try t.expect(!s.running);
        try t.expectEqual(@as(u32, 0), s.sample(now).trail_len);
    }
}

test "SmoothCursor same direction retarget preserves velocity and arrives without overshoot" {
    const t = std.testing;
    var s: Self = .{};
    _ = s.update(.{ 0, 0 }, .{ 19, 42 }, 19, 0, .block);
    _ = s.update(.{ 1000, 0 }, s.size, 19, 1, .block);
    const before = s.sample(1.05);
    const speed = s.velocity(1.05);
    const after = s.update(.{ 1500, 0 }, s.size, 19, 1.05, .block);
    try t.expectEqual(before.center, after.center);
    try t.expectApproxEqAbs(speed[0], s.velocity(1.05)[0], 0.001);
    var previous = after.center[0];
    for (1..221) |ms| {
        const pose = s.sample(1.05 + @as(f64, @floatFromInt(ms)) / 1000);
        try t.expect(pose.center[0] >= previous and pose.center[0] <= 1500);
        previous = pose.center[0];
    }
    try t.expectEqual(@as(Vec, .{ 1500, 0 }), s.sample(1.271).center);
    try t.expectEqual(@as(Vec, @splat(0)), s.velocity(1.271));
}

test "SmoothCursor turns bound lateral drift and strong reversal discards wrong way inertia" {
    const t = std.testing;
    for ([_]Vec{ .{ 0, 1000 }, .{ -1000, 0 }, .{ -600, 800 } }) |delta| {
        var s: Self = .{};
        _ = s.update(.{ 0, 0 }, .{ 19, 42 }, 19, 0, .block);
        _ = s.update(.{ 1000, 0 }, s.size, 19, 1, .block);
        const origin = s.sample(1.05).center;
        _ = s.update(origin + delta, s.size, 19, 1.05, .block);
        const direction = delta / @as(Vec, @splat(length(delta)));
        var previous: f32 = 0;
        for (0..221) |ms| {
            const offset = s.sample(1.05 + @as(f64, @floatFromInt(ms)) / 1000).center - origin;
            const along = @reduce(.Add, offset * direction);
            try t.expect(along >= previous - 0.001 and along <= length(delta) + 0.001);
            try t.expect(length(offset - direction * @as(Vec, @splat(along))) <= 19 * 0.25 + 0.001);
            previous = along;
        }
        if (delta[0] < 0) try t.expectEqual(@as(Vec, @splat(0)), s.velocity_from);
    }
}
