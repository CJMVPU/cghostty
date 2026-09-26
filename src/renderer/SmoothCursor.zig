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
const maximum_duration: f32 = 0.200;
// Bridge ordinary key-repeat gaps instead of closing on every cell arrival.
const burst_hold: f32 = 0.120;
const release: f32 = 0.100;
const geometry_duration: f32 = 0.100;

pub const Sample = struct {
    center: Vec,
    trail: [history_capacity]Vec = .{@as(Vec, @splat(0))} ** history_capacity,
    trail_len: u32 = 0,
    trail_radii: [history_capacity]f32 = .{0} ** history_capacity,
    size: Vec,
    roundness: f32 = 0,
    /// Text recoloring follows block-to-line shape transitions too.
    block_mix: f32 = 1,
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
size_from: Vec = @splat(0),
block_from: f32 = 1,
geometry_began: f64 = 0,
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

fn geometryProgress(self: *const Self, now: f64) f32 {
    const t = std.math.clamp(@as(f32, @floatCast(now - self.geometry_began)) / geometry_duration, 0, 1);
    return t * t * (3 - 2 * t);
}

fn nativeSize(self: *const Self, now: f64) Vec {
    const t = self.geometryProgress(now);
    if (t >= 1) return self.size;
    return self.size_from + (self.size - self.size_from) * @as(Vec, @splat(t));
}

fn blockMix(self: *const Self, now: f64) f32 {
    const target: f32 = if (self.shape == .block) 1 else 0;
    return self.block_from + (target - self.block_from) * self.geometryProgress(now);
}

pub fn sample(self: *const Self, now: f64) Sample {
    var pose: Sample = .{ .center = self.target, .size = self.nativeSize(now), .block_mix = self.blockMix(now) };
    if (self.running and now < self.hold_until + release) {
        const elapsed: f32 = @floatCast(@max(0, now - self.began));
        const t = if (self.duration > 0) std.math.clamp(elapsed / self.duration, 0, 1) else 1;
        const deform = self.amount(now);
        pose.center = self.origin + (self.target - self.origin) * @as(Vec, @splat(t * t * (3 - 2 * t))) +
            self.velocity_from * @as(Vec, @splat(self.duration * t * (1 - t) * (1 - t)));
        pose.size *= @as(Vec, @splat(1 + expansion * deform));
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
    if (!self.initialized) {
        self.* = .{
            .initialized = true,
            .origin = target,
            .target = target,
            .size = size,
            .size_from = size,
            .shape = shape,
            .block_from = if (shape == .block) 1 else 0,
        };
        return self.sample(now);
    }
    // Geometry has its own clock: changing width or mode must neither snap
    // position nor restart an in-flight move to the same target. Retarget from
    // the current interpolated size, without compounding the burst expansion.
    const geometry_changed = shape != self.shape or @reduce(.Or, size != self.size);
    if (geometry_changed) {
        self.size_from = self.nativeSize(now);
        self.block_from = self.blockMix(now);
        self.size = size;
        self.shape = shape;
        self.geometry_began = now;
    }
    if (length(target - self.target) >= 0.5) {
        const displayed = self.sample(now);
        // Nearby logical matches can arrive while the displayed body is still
        // far behind. Budget for that remaining travel too, instead of forcing
        // it into a one-cell duration. Keep the logical-step budget for turns
        // and reversals; both timings retain the same 200ms upper bound.
        const duration = @max(
            timing(target - self.target, timing_width),
            timing(target - displayed.center, timing_width),
        );
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
    if (geometry_changed) {
        if (!self.running or now > self.hold_until) {
            self.shape_from = self.amount(now);
            self.shape_began = now;
        }
        self.hold_until = @max(self.hold_until, now + geometry_duration);
        // Size-only transitions need a live draw schedule, even at rest.
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
    try t.expectApproxEqAbs(@as(f32, 0.200), timing(.{ 80, 0 }, 10), 0.000001);
    try t.expectApproxEqAbs(@as(f32, 0.064), timing(.{ 10, 0 }, 10) + tailLag(timing(.{ 10, 0 }, 10)), 0.000001);
    try t.expectApproxEqAbs(@as(f32, 0.260), timing(.{ 80, 0 }, 10) + tailLag(timing(.{ 80, 0 }, 10)), 0.000001);
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
            try std.testing.expectEqual(Sample{ .center = step, .size = cursor.size, .block_mix = if (cursor.shape == .block) 1 else 0 }, final);
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

test "SmoothCursor Vim redraws and geometry changes preserve motion" {
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
    const before_bar = s.sample(4);
    const bar = s.update(s.target, .{ 3, 20 }, 10, 4, .bar);
    try std.testing.expectEqual(before_bar, bar);
    try std.testing.expect(s.running);
    _ = s.update(s.target, s.size, 10, 4.5, .bar);
    try std.testing.expectEqual(@as(Vec, .{ 3, 20 }), s.sample(4.5).size);
    _ = s.update(s.target + @as(Vec, .{ 10, 0 }), s.size, 10, 5, .bar);
    try std.testing.expectApproxEqAbs(@as(f32, 3.36), s.sample(5.03).size[0], 0.000001);
    const before_resize = s.sample(5.04);
    const resized = s.update(s.target, .{ 3, 30 }, 15, 5.04, .bar);
    try std.testing.expectEqual(before_resize, resized);
    try std.testing.expect(s.running);
    try std.testing.expectEqual(@as(Vec, .{ 3, 30 }), s.update(s.target, s.size, 15, 5.5, .bar).size);
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
        try t.expect(length(s.sample(1 + 1.0 / 60.0).center) < 20);
        try t.expect(length(s.sample(1 + 1.0 / 120.0).center) < 6);
        try t.expectEqual(step, s.sample(1.201).center);
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
    // A shape transition retains the path already submitted to the display.
    const before_bar = s.sample(1.049);
    const bar = s.update(s.target, .{ 3, 42 }, 19, 1.049, .bar);
    try t.expectEqual(before_bar, bar);
    try t.expect(bar.trail_len > 0);
    try t.expect(s.history_len > 0);
}

test "SmoothCursor wide cells and all native shapes retarget continuously at multiple refresh rates" {
    const t = std.testing;
    const cursors = [_]struct { size: Vec, shape: Shape }{
        .{ .size = .{ 10, 20 }, .shape = .block },
        .{ .size = .{ 20, 20 }, .shape = .block },
        .{ .size = .{ 2, 20 }, .shape = .bar },
        .{ .size = .{ 10, 2 }, .shape = .underline },
        .{ .size = .{ 20, 2 }, .shape = .underline },
        .{ .size = .{ 30, 30 }, .shape = .block },
    };
    for ([_]f64{ 30, 60, 120, 240 }) |hz| {
        var s: Self = .{};
        s.recordFrame(0, s.update(.{ 0, 0 }, cursors[0].size, 10, 0, .block));
        for (1..121) |i| {
            const now = @as(f64, @floatFromInt(i)) / hz;
            const cursor = cursors[i % cursors.len];
            const before = s.sample(now);
            const pose = s.update(.{ @floatFromInt((i % 3) * 300), @floatFromInt((i % 5) * 100) }, cursor.size, 10, now, cursor.shape);
            try t.expectEqual(before, pose);
            try t.expect(s.running and s.effect(now) == 1);
            inline for (0..2) |axis| {
                try t.expect(std.math.isFinite(pose.center[axis]));
                try t.expect(pose.size[axis] >= 2 and pose.size[axis] <= 30 * 1.120001);
            }
            try t.expect(pose.block_mix >= 0 and pose.block_mix <= 1);
            s.recordFrame(now, pose);
        }
        // Record settling frames so the submitted trail can drain normally.
        const start = 120 / hz;
        for (1..121) |i| {
            const now = start + @as(f64, @floatFromInt(i)) / hz;
            s.recordFrame(now, s.update(s.target, s.size, 10, now, s.shape));
        }
        try t.expect(!s.running);
        const final = s.sample(start + 10);
        try t.expectEqual(s.target, final.center);
        try t.expectEqual(s.size, final.size);
        try t.expectEqual(@as(u32, 0), final.trail_len);
    }
}

test "SmoothCursor stationary geometry transitions finish and same-target changes keep travel deadline" {
    const t = std.testing;
    var s: Self = .{};
    _ = s.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0, .block);
    // Same timestamp and no position change: no zero-duration division/NaN.
    const initial = s.sample(0);
    try t.expectEqual(initial, s.update(s.target, .{ 2, 20 }, 10, 0, .bar));
    const middle = s.update(s.target, s.size, 10, 0.05, .bar);
    try t.expectEqual(s.target, middle.center);
    try t.expect(middle.size[0] > 2 and middle.size[0] < 10);
    try t.expectApproxEqAbs(@as(f32, 0.5), middle.block_mix, 0.000001);
    _ = s.update(s.target, s.size, 10, 0.5, .bar);
    try t.expect(!s.running and s.effect(0.5) == 0);
    try t.expectEqual(@as(Vec, .{ 2, 20 }), s.sample(0.5).size);

    _ = s.update(.{ 1000, 500 }, s.size, 10, 1, .bar);
    const deadline = s.began + s.duration;
    const before = s.sample(1.04);
    try t.expectEqual(before, s.update(s.target, .{ 20, 30 }, 15, 1.04, .block));
    try t.expectEqual(deadline, s.began + s.duration);
    try t.expectEqual(s.target, s.sample(deadline + 0.001).center);
    const release_pose = s.sample(s.hold_until + 0.04);
    try t.expectEqual(release_pose, s.update(s.target, .{ 20, 2 }, 15, s.hold_until + 0.04, .underline));
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
    for (1..201) |ms| {
        const pose = s.sample(1.05 + @as(f64, @floatFromInt(ms)) / 1000);
        try t.expect(pose.center[0] >= previous and pose.center[0] <= 1500);
        previous = pose.center[0];
    }
    try t.expectEqual(@as(Vec, .{ 1500, 0 }), s.sample(1.251).center);
    try t.expectEqual(@as(Vec, @splat(0)), s.velocity(1.251));
}

test "SmoothCursor nearby search match does not compress an unfinished long jump" {
    const t = std.testing;
    for ([_]Vec{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 }, .{ 0.6, 0.8 }, .{ -0.6, 0.8 }, .{ 0.6, -0.8 }, .{ -0.6, -0.8 } }) |direction| {
        var s: Self = .{};
        _ = s.update(.{ 0, 0 }, .{ 19, 42 }, 19, 0, .block);
        _ = s.update(direction * @as(Vec, @splat(1000)), s.size, 19, 1, .block);
        const before = s.sample(1.033);
        const speed = s.velocity(1.033);
        const target = direction * @as(Vec, @splat(1019));
        try t.expectEqual(before, s.update(target, s.size, 19, 1.033, .block));
        try t.expect(length(s.velocity(1.033) - speed) < 0.001);
        // A nearby logical match must not turn 946px of remaining travel
        // into a 24ms sprint (278px in the next 120Hz frame).
        try t.expect(length(s.sample(1.033 + 1.0 / 120.0).center - before.center) < 50);
        try t.expect(s.duration <= 0.200);
        var previous: f32 = @reduce(.Add, before.center * direction);
        for (1..202) |ms| {
            const pose = s.sample(1.033 + @as(f64, @floatFromInt(ms)) / 1000);
            const along = @reduce(.Add, pose.center * direction);
            try t.expect(along >= previous - 0.001 and along <= 1019.001);
            previous = along;
        }
        try t.expectEqual(target, s.sample(1.234).center);
    }
}

test "SmoothCursor repeated nearby matches settle and ordinary cell input stays fast" {
    const t = std.testing;
    for ([_]f64{ 0.008, 0.016, 0.033, 0.060, 0.100 }) |interval| {
        var s: Self = .{};
        _ = s.update(.{ 0, 0 }, .{ 19, 42 }, 19, 0, .block);
        _ = s.update(.{ 1000, 0 }, s.size, 19, 1, .block);
        for (1..101) |i| {
            const now = 1 + @as(f64, @floatFromInt(i)) * interval;
            const before = s.sample(now);
            const target: Vec = .{ 1000 + 19 * @as(f32, @floatFromInt(i)), 0 };
            try t.expectEqual(before, s.update(target, s.size, 19, now, .block));
            try t.expect(s.duration <= 0.200);
            try t.expect(s.velocity(now)[0] >= 0);
        }
        try t.expectEqual(s.target, s.sample(s.began + 0.201).center);
        _ = s.update(s.target, s.size, 19, s.began + 1, .block);
        try t.expect(!s.running);
    }
    var short: Self = .{};
    _ = short.update(.{ 0, 0 }, .{ 19, 42 }, 19, 0, .block);
    for (1..101) |i| {
        const now = @as(f64, @floatFromInt(i)) * 0.033;
        _ = short.update(.{ 19 * @as(f32, @floatFromInt(i)), 0 }, short.size, 19, now, .block);
        try t.expectApproxEqAbs(@as(f32, 0.024), short.duration, 0.000001);
    }
}

test "SmoothCursor nearby search retarget preserves English Chinese and line geometry transitions" {
    const t = std.testing;
    const Geometry = struct { size: Vec, shape: Shape };
    const geometries = [_]Geometry{
        .{ .size = .{ 19, 42 }, .shape = .block },
        .{ .size = .{ 38, 42 }, .shape = .block },
        .{ .size = .{ 3, 42 }, .shape = .bar },
        .{ .size = .{ 38, 3 }, .shape = .underline },
    };
    for (geometries) |from| {
        for (geometries) |to| {
            var s: Self = .{};
            _ = s.update(.{ 0, 0 }, from.size, 19, 0, from.shape);
            _ = s.update(.{ 1000, 0 }, from.size, 19, 1, from.shape);
            const before = s.sample(1.033);
            try t.expectEqual(before, s.update(.{ 1019, 0 }, to.size, 19, 1.033, to.shape));
            try t.expect(s.sample(1.033 + 1.0 / 120.0).center[0] - before.center[0] < 50);
            // Geometry still takes 100ms independently of the travel budget.
            const middle = s.sample(1.083);
            const expected = (from.size + to.size) * @as(Vec, @splat(0.5 * 1.12));
            inline for (0..2) |axis| try t.expectApproxEqAbs(expected[axis], middle.size[axis], 0.0001);
            const geometry_done = s.sample(1.134);
            inline for (0..2) |axis| try t.expectApproxEqAbs(to.size[axis] * 1.12, geometry_done.size[axis], 0.0001);
            try t.expect(geometry_done.center[0] < 1019);
            try t.expectEqual(@as(Vec, .{ 1019, 0 }), s.sample(1.234).center);
            const settled = s.update(s.target, to.size, 19, 1.5, to.shape);
            try t.expectEqual(to.size, settled.size);
            try t.expect(!s.running);
        }
    }
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
        for (0..201) |ms| {
            const offset = s.sample(1.05 + @as(f64, @floatFromInt(ms)) / 1000).center - origin;
            const along = @reduce(.Add, offset * direction);
            try t.expect(along >= previous - 0.001 and along <= length(delta) + 0.001);
            try t.expect(length(offset - direction * @as(Vec, @splat(along))) <= 19 * 0.25 + 0.001);
            previous = along;
        }
        if (delta[0] < 0) try t.expectEqual(@as(Vec, @splat(0)), s.velocity_from);
    }
}
