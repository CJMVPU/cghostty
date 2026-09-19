//! Stateful dual-end cursor motion. Time is in seconds and geometry in pixels.
//! Single moves match the user's smooth-cursor.glsl timing. Interruptions start
//! at the currently displayed endpoints, never the previous terminal cell.
const Self = @This();
const std = @import("std");
pub const Vec = @Vector(2, f32);
pub const Sample = struct { front: Vec, rear: Vec };

initialized: bool = false,
running: bool = false,
start: Sample = .{ .front = @splat(0), .rear = @splat(0) },
target: Vec = @splat(0),
size: Vec = @splat(0),
began: f64 = 0,
duration: f32 = 0,
delay: f32 = 0,

pub fn progress(t_: f32) f32 {
    const t = std.math.clamp(t_, 0, 1);
    const a: f32 = 0.10;
    const b: f32 = 0.65;
    const area = 1 - 0.5 * (a + 1 - b);
    if (t < a) {
        const u = t / a;
        return a * (u * u * u - 0.5 * u * u * u * u) / area;
    }
    if (t <= b) return (t - 0.5 * a) / area;
    const u = (t - b) / (1 - b);
    return (b - 0.5 * a + (1 - b) * (u - u * u * u + 0.5 * u * u * u * u)) / area;
}

fn length(v: Vec) f32 {
    return @sqrt(@reduce(.Add, v * v));
}

pub fn timing(delta: Vec, width: f32) struct { duration: f32, delay: f32 } {
    const distance = length(delta) / @max(width, 1);
    const x = std.math.clamp((distance - 1) / 7, 0, 1);
    const weight = x * x * (3 - 2 * x);
    return .{
        .duration = 0.024 + (0.180 - 0.024) * weight,
        .delay = if (distance <= 2.0001) 0.020 else if (distance <= 8.0001) 0.040 else 0.060,
    };
}

pub fn sample(self: Self, now: f64) Sample {
    if (!self.running) return .{ .front = self.target, .rear = self.target };
    const elapsed: f32 = @floatCast(@max(0, now - self.began));
    const f = progress(elapsed / self.duration);
    const r = progress((elapsed - self.delay) / self.duration);
    return .{
        .front = self.start.front + (self.target - self.start.front) * @as(Vec, @splat(f)),
        .rear = self.start.rear + (self.target - self.start.rear) * @as(Vec, @splat(r)),
    };
}

pub fn reset(self: *Self) void {
    self.* = .{};
}

pub fn update(self: *Self, target: Vec, size: Vec, timing_width: f32, now: f64) Sample {
    if (!self.initialized or @reduce(.Or, size != self.size)) {
        self.* = .{ .initialized = true, .target = target, .size = size };
        return self.sample(now);
    }
    if (length(target - self.target) >= 0.5) {
        const displayed = self.sample(now);
        // Use this input step, not accumulated visual lag, for timing.
        // Reusing the remaining delay prevents rapid input from holding
        // the rear still forever. Both endpoints still start at their
        // current positions, with no discontinuous trail-length clamp.
        const motion = timing(target - self.target, timing_width);
        const elapsed: f32 = @floatCast(@max(0, now - self.began));
        const interrupted = self.running and elapsed < self.duration + self.delay;
        const delay = if (interrupted) @max(0, self.delay - elapsed) else motion.delay;
        self.start = displayed;
        self.target = target;
        self.began = now;
        self.duration = motion.duration;
        self.delay = delay;
        self.running = true;
    }
    if (now - self.began >= @as(f64, self.duration + self.delay)) self.running = false;
    return self.sample(now);
}

/// Fade the shape to the native rectangle only as both endpoints arrive.
pub fn effect(self: Self, now: f64) f32 {
    if (!self.running) return 0;
    const elapsed: f32 = @floatCast(@max(0, now - self.began));
    const handoff = @min(@as(f32, 0.020), self.duration * 0.25);
    const x = std.math.clamp((elapsed - (self.duration + self.delay - handoff)) / handoff, 0, 1);
    const fade = x * x * x * (x * (x * 6 - 15) + 10);
    const p = self.sample(now);
    const remaining = @max(length(p.front - self.target), length(p.rear - self.target));
    const near = std.math.clamp((remaining - 0.75) / 0.75, 0, 1);
    return 1 - fade * (1 - near * near * (3 - 2 * near));
}

test "SmoothCursor original timing and rotational invariance" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f32, 0.024), timing(.{ 10, 0 }, 10).duration, 0.000001);
    try t.expectApproxEqAbs(@as(f32, 0.180), timing(.{ 80, 0 }, 10).duration, 0.000001);
    try t.expectEqual(@as(f32, 0.020), timing(.{ 20, 0 }, 10).delay);
    try t.expectEqual(@as(f32, 0.040), timing(.{ 80, 0 }, 10).delay);
    try t.expectEqual(@as(f32, 0.060), timing(.{ 81, 0 }, 10).delay);
    try t.expectEqual(timing(.{ 30, 40 }, 10), timing(.{ 0, 50 }, 10));
    var last: f32 = 0;
    for (0..1001) |i| {
        const p = progress(@as(f32, @floatFromInt(i)) / 1000);
        try t.expect(p >= last and p <= 1.000001);
        last = p;
    }
}

test "SmoothCursor both endpoints continue exactly on interruption" {
    var state: Self = .{};
    _ = state.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0);
    _ = state.update(.{ 100, 0 }, .{ 10, 20 }, 10, 1);
    const before = state.sample(1.08);
    const after = state.update(.{ 50, 100 }, .{ 10, 20 }, 10, 1.08);
    try std.testing.expectEqual(before, after);
    try std.testing.expect(before.front[0] != before.rear[0]);
    const end = state.update(.{ 50, 100 }, .{ 10, 20 }, 10, 2);
    try std.testing.expectEqual(@as(Vec, .{ 50, 100 }), end.front);
    try std.testing.expectEqual(end.front, end.rear);
    try std.testing.expect(!state.running);
}

test "SmoothCursor front arrival keeps rear alive and resize resets" {
    var state: Self = .{};
    _ = state.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0);
    _ = state.update(.{ 100, 0 }, .{ 10, 20 }, 10, 1);
    const p = state.update(.{ 100, 0 }, .{ 10, 20 }, 10, 1.181);
    try std.testing.expectEqual(@as(f32, 100), p.front[0]);
    try std.testing.expect(p.rear[0] < 100 and state.running);
    _ = state.update(.{ 100, 0 }, .{ 20, 20 }, 10, 1.19);
    try std.testing.expect(!state.running);
    state.reset();
    _ = state.update(.{ 800, 300 }, .{ 10, 20 }, 10, 2);
    try std.testing.expect(!state.running);
}

// These inputs reproduce key repeat faster than the original rear delay.
test "SmoothCursor vertical key repeat cannot starve rear or accumulate a long trail" {
    for ([_]f64{ 0.008, 0.016, 0.033 }) |interval| {
        var state: Self = .{};
        _ = state.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0);
        for (1..501) |i| {
            const now = @as(f64, @floatFromInt(i)) * interval;
            const target: Vec = .{ 0, @as(f32, @floatFromInt(i)) * 20 };
            const before = state.sample(now);
            const after = state.update(target, .{ 10, 20 }, 10, now);
            try std.testing.expectEqual(before, after);
            try std.testing.expect(length(after.front - after.rear) < 40);
            try std.testing.expect(length(target - after.rear) < 100);
            try std.testing.expectApproxEqAbs(timing(.{ 0, 20 }, 10).duration, state.duration, 0.000001);
        }
        const end = state.update(state.target, state.size, 10, state.began + 1);
        try std.testing.expectEqual(state.target, end.rear);
        try std.testing.expect(!state.running);
    }
}

test "SmoothCursor beam uses cell width for timing and animates after mode switch" {
    var state: Self = .{};
    _ = state.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0);
    _ = state.update(.{ 0, 0 }, .{ 2, 20 }, 10, 1);
    try std.testing.expect(!state.running);
    _ = state.update(.{ 10, 0 }, .{ 2, 20 }, 10, 2);
    try std.testing.expectEqual(timing(.{ 10, 0 }, 10).duration, state.duration);
    const pose = state.update(.{ 10, 0 }, .{ 2, 20 }, 10, 2.012);
    try std.testing.expect(pose.front[0] > 0 and pose.front[0] < 10);
    try std.testing.expect(state.running);
}
