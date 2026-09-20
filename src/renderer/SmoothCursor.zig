//! Directional four-corner cursor motion, in seconds and screen pixels.
//! Retarget from the displayed corners. Different response times (not restarted
//! delays) keep the leading and trailing edges distinct during key repeat.
const Self = @This();
const std = @import("std");
pub const Vec = @Vector(2, f32);
pub const Shape = enum { block, bar, underline };
// Clockwise in screen coordinates: top-left, top-right, bottom-right, bottom-left.
const signs = [4]Vec{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
pub const Sample = struct {
    corners: [4]Vec,
    expansion: [4]Vec = .{@as(Vec, @splat(0))} ** 4,

    fn rectangle(center: Vec, size: Vec) Sample {
        var result: Sample = .{ .corners = undefined };
        for (&result.corners, signs) |*corner, sign| corner.* = center + sign * size * @as(Vec, @splat(0.5));
        return result;
    }

    /// A tight reversal can move a corner inside the other three. Render the
    /// convex outline of the actual points instead of a self-intersecting quad.
    pub fn outline(self: Sample, size: Vec) Outline {
        var points = self.corners;
        for (1..4) |i| {
            var j = i;
            while (j > 0 and (points[j][0] < points[j - 1][0] or
                (points[j][0] == points[j - 1][0] and points[j][1] < points[j - 1][1]))) : (j -= 1)
            {
                std.mem.swap(Vec, &points[j], &points[j - 1]);
            }
        }
        var hull: [8]Vec = undefined;
        var n: usize = 0;
        for (points) |point| {
            while (n >= 2 and cross(hull[n - 1] - hull[n - 2], point - hull[n - 1]) <= 0) n -= 1;
            hull[n] = point;
            n += 1;
        }
        const lower = n;
        var i: usize = 3;
        while (i > 0) {
            i -= 1;
            const point = points[i];
            while (n > lower and cross(hull[n - 1] - hull[n - 2], point - hull[n - 1]) <= 0) n -= 1;
            hull[n] = point;
            n += 1;
        }
        n -= 1; // repeated first point
        if (n < 3) {
            // Keep even a degenerate, very thin cursor visible on a reversal.
            var center: Vec = @splat(0);
            for (points) |point| center += point * @as(Vec, @splat(0.25));
            return .{ .corners = rectangle(center, size).corners, .count = 4 };
        }
        var result: Outline = .{ .corners = undefined, .count = @intCast(n) };
        for (0..4) |k| result.corners[k] = hull[@min(k, n - 1)];
        return result;
    }
};

pub const Outline = struct { corners: [4]Vec, count: u32 };

fn cross(a: Vec, b: Vec) f32 {
    return a[0] * b[1] - a[1] * b[0];
}

initialized: bool = false,
running: bool = false,
hidden: bool = false,
start: Sample = .{ .corners = .{@as(Vec, @splat(0))} ** 4 },
lead: [4]f32 = .{0} ** 4,
normal: Vec = .{ 0, 1 },
target: Vec = @splat(0),
size: Vec = @splat(0),
shape: Shape = .block,
began: f64 = 0,
duration: f32 = 0,
lag: f32 = 0,

/// Nonzero initial slope prevents repeated retargeting from restarting a
/// slow acceleration phase. Zero arrival slope restores the resting shape.
pub fn progress(t_: f32) f32 {
    const t = std.math.clamp(t_, 0, 1);
    const remaining = 1 - t;
    return 1 - remaining * remaining * remaining;
}

fn length(v: Vec) f32 {
    return @sqrt(@reduce(.Add, v * v));
}

pub fn timing(delta: Vec, width: f32) struct { duration: f32, lag: f32 } {
    const distance = length(delta) / @max(width, 1);
    const x = std.math.clamp((distance - 1) / 7, 0, 1);
    const weight = x * x * (3 - 2 * x);
    return .{
        .duration = 0.024 + (0.180 - 0.024) * weight,
        .lag = if (distance <= 2.0001) 0.020 else if (distance <= 8.0001) 0.040 else 0.060,
    };
}

pub fn sample(self: Self, now: f64) Sample {
    const destination = Sample.rectangle(self.target, self.size);
    if (!self.running) return destination;
    const elapsed: f32 = @floatCast(@max(0, now - self.began));
    var result: Sample = .{ .corners = undefined };
    for (&result.corners, 0..) |*corner, i| {
        const duration = self.duration + self.lag * (1 - self.lead[i]);
        const p = progress(elapsed / duration);
        corner.* = self.start.corners[i] + (destination.corners[i] - self.start.corners[i]) * @as(Vec, @splat(p));

        // Open the leading edge perpendicular to travel, then restore it.
        // Thin bars/underlines keep their native thickness. The expansion is
        // zero at both endpoints, including the exact instant of a retarget.
        const envelope = 4 * p * (1 - p);
        const amount = 0.15 * self.lead[i] * envelope;
        const half = self.size * @as(Vec, @splat(0.5));
        const across = @reduce(.Add, signs[i] * half * self.normal);
        // Carry the previous flare separately: repeated retargets must not
        // stack expansions and inflate the cursor beyond the intended size.
        const retained = self.start.expansion[i] * @as(Vec, @splat(1 - p));
        const limit = half * @as(Vec, @splat(0.15));
        var expansion = retained + self.normal * @as(Vec, @splat(across * amount));
        expansion = @min(limit, @max(-limit, expansion));
        inline for (0..2) |axis| {
            if (self.size[axis] <= 3 or
                (self.shape == .bar and axis == 0) or
                (self.shape == .underline and axis == 1)) expansion[axis] = 0;
        }
        result.expansion[i] = expansion;
        corner.* += expansion - retained;
    }
    return result;
}

pub fn reset(self: *Self) void {
    self.* = .{};
}

/// Suppress drawing during a terminal redraw/blink without forgetting motion.
pub fn hide(self: *Self) void {
    self.hidden = true;
}

pub fn update(self: *Self, target: Vec, size: Vec, timing_width: f32, now: f64, shape: Shape) Sample {
    self.hidden = false;
    if (!self.initialized or shape != self.shape or @reduce(.Or, size != self.size)) {
        self.* = .{ .initialized = true, .target = target, .size = size, .shape = shape };
        return self.sample(now);
    }
    if (length(target - self.target) >= 0.5) {
        const displayed = self.sample(now);
        // Input distance sets timing, not accumulated visual lag. The rear
        // always has a slower response; key repeat must not consume this lag.
        const delta = target - self.target;
        const motion = timing(delta, timing_width);
        // Input distance still controls timing, but the leading edge belongs
        // to the actual on-screen travel. A new target behind the old target
        // can remain ahead of the displayed cursor while it is catching up.
        var center: Vec = @splat(0);
        for (displayed.corners) |corner| center += corner * @as(Vec, @splat(0.25));
        const travel = if (length(target - center) >= 0.5) target - center else delta;
        const direction = travel / @as(Vec, @splat(length(travel)));
        self.normal = .{ -direction[1], direction[0] };
        const span = @abs(direction[0]) + @abs(direction[1]);
        for (&self.lead, signs) |*lead, sign| {
            lead.* = std.math.clamp(0.5 + 0.5 * @reduce(.Add, sign * direction) / span, 0, 1);
        }
        self.start = displayed;
        self.target = target;
        self.began = now;
        self.duration = motion.duration;
        self.lag = motion.lag;
        self.running = true;
    }
    if (now - self.began >= @as(f64, self.duration + self.lag)) self.running = false;
    return self.sample(now);
}

/// Fade only once all corners are close to their native positions.
pub fn effect(self: Self, now: f64) f32 {
    if (!self.running or self.hidden) return 0;
    const elapsed: f32 = @floatCast(@max(0, now - self.began));
    const handoff = @min(@as(f32, 0.020), self.duration * 0.25);
    const x = std.math.clamp((elapsed - (self.duration + self.lag - handoff)) / handoff, 0, 1);
    const fade = x * x * x * (x * (x * 6 - 15) + 10);
    const pose = self.sample(now);
    const destination = Sample.rectangle(self.target, self.size);
    var remaining: f32 = 0;
    for (pose.corners, destination.corners) |corner, goal| remaining = @max(remaining, length(corner - goal));
    const near = std.math.clamp((remaining - 0.75) / 0.75, 0, 1);
    return 1 - fade * (1 - near * near * (3 - 2 * near));
}

test "SmoothCursor distance timing and monotone response" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f32, 0.024), timing(.{ 10, 0 }, 10).duration, 0.000001);
    try t.expectApproxEqAbs(@as(f32, 0.180), timing(.{ 80, 0 }, 10).duration, 0.000001);
    try t.expectEqual(@as(f32, 0.020), timing(.{ 20, 0 }, 10).lag);
    try t.expectEqual(@as(f32, 0.040), timing(.{ 80, 0 }, 10).lag);
    try t.expectEqual(@as(f32, 0.060), timing(.{ 81, 0 }, 10).lag);
    try t.expectEqual(timing(.{ 30, 40 }, 10), timing(.{ 0, 50 }, 10));
    var last: f32 = 0;
    for (0..1001) |i| {
        const p = progress(@as(f32, @floatFromInt(i)) / 1000);
        try t.expect(p >= last and p <= 1);
        last = p;
    }
}

test "SmoothCursor eight directions lead with the correct edges and corners" {
    const directions = [_]Vec{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 }, .{ 1, 1 }, .{ -1, 1 }, .{ -1, -1 }, .{ 1, -1 } };
    for (directions) |direction| {
        var state: Self = .{};
        const size: Vec = .{ 10, 20 };
        const initial = state.update(.{ 0, 0 }, size, 10, 0, .block);
        _ = state.update(direction * @as(Vec, @splat(100)), size, 10, 1, .block);
        const pose = state.sample(1.06);
        for (signs, 0..) |a, i| {
            for (signs, 0..) |b, j| {
                const lead_a = @reduce(.Add, a * direction);
                const lead_b = @reduce(.Add, b * direction);
                const travel_a = @reduce(.Add, (pose.corners[i] - initial.corners[i]) * direction);
                const travel_b = @reduce(.Add, (pose.corners[j] - initial.corners[j]) * direction);
                if (lead_a > lead_b) try std.testing.expect(travel_a > travel_b);
                if (lead_a == lead_b) try std.testing.expectApproxEqAbs(travel_a, travel_b, 0.001);
            }
        }
        const final = state.update(state.target, size, 10, 2, .block);
        try std.testing.expectEqual(Sample.rectangle(state.target, size), final);
        try std.testing.expect(!state.running and state.effect(2) == 0);
    }
}

test "SmoothCursor leading edge expands at most fifteen percent then restores" {
    for ([_]Vec{ .{ 100, 0 }, .{ 0, 100 } }) |target| {
        var state: Self = .{};
        _ = state.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0, .block);
        _ = state.update(target, .{ 10, 20 }, 10, 1, .block);
        var largest: f32 = 0;
        const horizontal = target[0] > 0;
        const original: f32 = if (horizontal) 20 else 10;
        for (0..241) |i| {
            const p = state.sample(1 + @as(f64, @floatFromInt(i)) / 1000);
            const edge = if (horizontal) p.corners[2] - p.corners[1] else p.corners[2] - p.corners[3];
            const rear = if (horizontal) p.corners[3] - p.corners[0] else p.corners[1] - p.corners[0];
            largest = @max(largest, length(edge));
            try std.testing.expect(length(edge) <= original * 1.151);
            try std.testing.expectApproxEqAbs(original, length(rear), 0.001);
        }
        try std.testing.expect(largest > original * 1.14);
        try std.testing.expectEqual(Sample.rectangle(target, state.size), state.sample(2));
    }
}

test "SmoothCursor retarget preserves all displayed corners on reversal" {
    var state: Self = .{};
    _ = state.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0, .block);
    _ = state.update(.{ 100, 0 }, .{ 10, 20 }, 10, 1, .block);
    const before = state.sample(1.08);
    const after = state.update(.{ -50, 100 }, .{ 10, 20 }, 10, 1.08, .block);
    try std.testing.expectEqual(before, after);
    const end = state.update(state.target, state.size, 10, 2, .block);
    try std.testing.expectEqual(Sample.rectangle(state.target, state.size), end);
    try std.testing.expect(!state.running);
}

test "SmoothCursor vertical key repeat retains trailing motion without unbounded lag" {
    for ([_]f64{ 0.008, 0.016, 0.033 }) |interval| {
        var state: Self = .{};
        _ = state.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0, .block);
        for (1..501) |i| {
            const now = @as(f64, @floatFromInt(i)) * interval;
            const target: Vec = .{ 0, @as(f32, @floatFromInt(i)) * 20 };
            const before = state.sample(now);
            const after = state.update(target, state.size, 10, now, .block);
            try std.testing.expectEqual(before, after);
            const pose = state.sample(now + interval * 0.5);
            const top = pose.corners[0][1] + 10;
            const bottom = pose.corners[3][1] - 10;
            try std.testing.expect(bottom > top);
            try std.testing.expect(bottom - top < 80);
            try std.testing.expect(target[1] - top < 100);
            try std.testing.expect(state.effect(now + interval * 0.5) > 0);
        }
        _ = state.update(state.target, state.size, 10, state.began + 1, .block);
        try std.testing.expect(!state.running);
    }
}

test "SmoothCursor repeated Vim search redraws never discard the animation" {
    const matches = [_]Vec{ .{ 30, 40 }, .{ 400, 40 }, .{ 150, 240 }, .{ 600, 100 }, .{ 10, 360 } };
    for ([_]f64{ 0.008, 0.016, 0.033 }) |interval| {
        var state: Self = .{};
        _ = state.update(matches[0], .{ 10, 20 }, 10, 0, .block);
        for (1..501) |i| {
            const now = @as(f64, @floatFromInt(i)) * interval;
            // DECTCEM hide/show can fall in separate rendered frames.
            state.hide();
            try std.testing.expectEqual(@as(f32, 0), state.effect(now));
            const before = state.sample(now);
            const pose = state.update(matches[i % matches.len], state.size, 10, now, .block);
            try std.testing.expectEqual(before, pose);
            try std.testing.expect(state.running and state.effect(now) > 0);
            const advanced = state.sample(now + interval * 0.5);
            var movement: f32 = 0;
            for (advanced.corners, pose.corners) |a, b| movement = @max(movement, length(a - b));
            try std.testing.expect(movement > 0.5);
        }
        const end = state.update(state.target, state.size, 10, state.began + 1, .block);
        try std.testing.expectEqual(Sample.rectangle(state.target, state.size), end);
        try std.testing.expect(!state.running);
        // An idle blink also must not forget where the next move starts.
        state.hide();
        _ = state.update(.{ 100, 100 }, state.size, 10, state.began + 2, .block);
        try std.testing.expect(state.running);
    }
}

test "SmoothCursor Vim mode changes and thin cursor thickness" {
    for ([_]Vec{ .{ 1, 20 }, .{ 2, 20 }, .{ 3, 20 }, .{ 4, 20 }, .{ 10, 1 }, .{ 10, 2 }, .{ 10, 4 } }) |size| {
        var state: Self = .{};
        _ = state.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0, .block);
        const bar = size[0] < size[1];
        const shape: Shape = if (bar) .bar else .underline;
        _ = state.update(.{ 0, 0 }, size, 10, 1, shape);
        try std.testing.expect(!state.running);
        const target: Vec = if (bar) .{ 0, 20 } else .{ 10, 0 };
        _ = state.update(target, size, 10, 2, shape);
        try std.testing.expectEqual(timing(target, 10).duration, state.duration);
        for (0..101) |i| {
            const pose = state.sample(2 + @as(f64, @floatFromInt(i)) / 1000);
            const thickness = if (bar) pose.corners[1][0] - pose.corners[0][0] else pose.corners[3][1] - pose.corners[0][1];
            try std.testing.expectApproxEqAbs(if (bar) size[0] else size[1], thickness, 0.001);
        }
        _ = state.update(target, .{ 10, 20 }, 10, 3, .block);
        try std.testing.expect(!state.running);
        _ = state.update(.{ 100, 100 }, .{ 10, 20 }, 10, 4, .block);
        try std.testing.expect(state.running);
        state.reset();
        _ = state.update(.{ 800, 300 }, .{ 10, 20 }, 10, 5, .block);
        try std.testing.expect(!state.running);
    }
}

test "SmoothCursor rapid reversals have a convex finite visible outline" {
    for ([_]Vec{ .{ 10, 20 }, .{ 1, 20 }, .{ 10, 1 } }) |size| {
        var state: Self = .{};
        _ = state.update(.{ 300, 200 }, size, 10, 0, .block);
        var rng = std.Random.DefaultPrng.init(42);
        const random = rng.random();
        for (1..501) |i| {
            const now = @as(f64, @floatFromInt(i)) * 0.016;
            _ = state.update(.{ random.float(f32) * 600, random.float(f32) * 400 }, size, 10, now, .block);
            for (0..4) |frame| {
                const pose = state.sample(now + @as(f64, @floatFromInt(frame)) * 0.004);
                const outline = pose.outline(size);
                try std.testing.expect(outline.count >= 3 and outline.count <= 4);
                var area: f32 = 0;
                for (0..outline.count) |j| {
                    const a = outline.corners[j];
                    const b = outline.corners[(j + 1) % outline.count];
                    area += cross(a - outline.corners[0], b - outline.corners[0]);
                    try std.testing.expect(std.math.isFinite(a[0]) and std.math.isFinite(a[1]));
                    for (pose.corners) |point| try std.testing.expect(cross(b - a, point - a) >= -0.1);
                }
                try std.testing.expect(area > 0);
            }
        }
    }
}

test "SmoothCursor held key cannot accumulate leading edge expansion" {
    for ([_]Vec{ .{ 10, 0 }, .{ 0, 20 } }) |step| {
        var state: Self = .{};
        _ = state.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0, .block);
        for (1..501) |i| {
            const now = @as(f64, @floatFromInt(i)) * 0.008;
            const before = state.sample(now);
            const pose = state.update(step * @as(Vec, @splat(@floatFromInt(i))), state.size, 10, now, .block);
            try std.testing.expectEqual(before, pose);
            const p = state.sample(now + 0.004);
            const horizontal = step[0] > 0;
            const edge = if (horizontal) p.corners[2] - p.corners[1] else p.corners[2] - p.corners[3];
            try std.testing.expect(length(edge) <= (if (horizontal) @as(f32, 20) else 10) * 1.151);
        }
        const end = state.update(state.target, state.size, 10, state.began + 1, .block);
        try std.testing.expectEqual(Sample.rectangle(state.target, state.size), end);
    }
}

test "SmoothCursor retarget chooses the front from displayed travel" {
    var state: Self = .{};
    _ = state.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0, .block);
    _ = state.update(.{ 100, 0 }, state.size, 10, 1, .block);
    const before = state.sample(1.04);
    // The logical target moves left, but the displayed cursor must still
    // travel right. Its right edge must remain the faster edge.
    _ = state.update(.{ 80, 0 }, state.size, 10, 1.04, .block);
    const after = state.sample(1.05);
    const left = (after.corners[0][0] - before.corners[0][0]) / (75 - before.corners[0][0]);
    const right = (after.corners[1][0] - before.corners[1][0]) / (85 - before.corners[1][0]);
    try std.testing.expect(right > left);
    try std.testing.expectEqual(timing(.{ -20, 0 }, 10).duration, state.duration);
}
