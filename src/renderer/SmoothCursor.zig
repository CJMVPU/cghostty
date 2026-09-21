//! A stable cursor body with a separate trailing follower.
//! Shape follows an input burst independently of each positional retarget.
const Self = @This();
const std = @import("std");
pub const Vec = @Vector(2, f32);
pub const Shape = enum { block, bar, underline };

pub const expansion: f32 = 0.12;
const attack: f32 = 0.024;
const tail_lag: f32 = 0.040;
// Bridge ordinary key-repeat gaps instead of closing on every cell arrival.
const burst_hold: f32 = 0.120;
const release: f32 = 0.100;

pub const Sample = struct {
    center: Vec,
    tail_offset: Vec = @splat(0),
    size: Vec,
    roundness: f32 = 0,
};

initialized: bool = false,
running: bool = false,
hidden: bool = false,
origin: Vec = @splat(0),
tail_origin_offset: Vec = @splat(0),
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
    return 0.024 + (0.180 - 0.024) * x * x * (3 - 2 * x);
}

fn amount(self: Self, now: f64) f32 {
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

pub fn sample(self: Self, now: f64) Sample {
    if (!self.running or now >= self.hold_until + release) return .{
        .center = self.target,
        .size = self.size,
    };
    const elapsed: f32 = @floatCast(@max(0, now - self.began));
    const p = progress(elapsed / self.duration);
    const deform = self.amount(now);
    const rear = progress(elapsed / (self.duration + tail_lag));
    // Evaluate the relative offset directly to avoid loss of precision when
    // subtracting two large screen positions. Retarget preserves this offset.
    const offset = (self.target - self.origin) * @as(Vec, @splat(rear - p)) +
        self.tail_origin_offset * @as(Vec, @splat(1 - rear));
    return .{
        .center = self.origin + (self.target - self.origin) * @as(Vec, @splat(p)),
        .tail_offset = offset,
        .size = self.size * @as(Vec, @splat(1 + expansion * deform)),
        .roundness = deform,
    };
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
        // Continue an opening/held shape without restarting its envelope.
        // If a new burst interrupts release, open from the displayed amount.
        if (!self.running or now > self.hold_until) {
            self.shape_from = displayed.roundness;
            self.shape_began = now;
        }
        self.origin = displayed.center;
        self.tail_origin_offset = displayed.tail_offset;
        self.target = target;
        self.began = now;
        self.duration = duration;
        self.hold_until = now + @max(duration + tail_lag, burst_hold);
        self.running = true;
    }
    if (now >= self.hold_until + release) self.running = false;
    return self.sample(now);
}

/// Blend the final subpixel rounding into the exact native glyph.
pub fn effect(self: Self, now: f64) f32 {
    if (!self.running or self.hidden) return 0;
    if (now <= self.hold_until) return 1;
    return std.math.clamp(self.amount(now) / 0.02, 0, 1);
}

test "SmoothCursor distance timing and monotone center response" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f32, 0.024), timing(.{ 10, 0 }, 10), 0.000001);
    try t.expectApproxEqAbs(@as(f32, 0.180), timing(.{ 80, 0 }, 10), 0.000001);
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
    try t.expect(std.math.isFinite(pose.tail_offset[0]) and std.math.isFinite(pose.tail_offset[1]));
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

test "SmoothCursor follower moves after body arrival without shrinking the body" {
    const t = std.testing;
    for ([_]Vec{ .{ 10, 0 }, .{ -10, 0 }, .{ 0, 20 }, .{ 0, -20 } }) |step| {
        for ([_]struct { size: Vec, shape: Shape }{
            .{ .size = .{ 10, 20 }, .shape = .block },
            .{ .size = .{ 3, 20 }, .shape = .bar },
            .{ .size = .{ 10, 3 }, .shape = .underline },
        }) |cursor| {
            var s: Self = .{};
            _ = s.update(.{ 0, 0 }, cursor.size, 10, 0, cursor.shape);
            _ = s.update(step, cursor.size, 10, 1, cursor.shape);
            const arrived = 1 + @as(f64, s.duration);
            const first = s.sample(arrived + 0.008);
            const next = s.sample(arrived + 0.024);
            try t.expectEqual(step, first.center);
            try t.expectEqual(first.center, next.center);
            try t.expect(length(first.tail_offset) > 0.01);
            try t.expect(length(next.tail_offset) < length(first.tail_offset));
            try t.expect(@reduce(.Add, first.tail_offset * step) < 0);
            try t.expectEqual(first.size, next.size);
            try expectUniform(first, cursor.size);
            try t.expectEqual(@as(Vec, @splat(0)), s.sample(arrived + 0.041).tail_offset);
        }
    }
}

test "SmoothCursor rapid long jumps and reversals keep follower continuous within the travel region" {
    const t = std.testing;
    for ([_]f64{ 0.008, 0.016, 0.033, 0.060 }) |interval| {
        var s: Self = .{};
        _ = s.update(.{ 0, 0 }, .{ 10, 20 }, 10, 0, .block);
        const targets = [_]Vec{ .{ 1800, 900 }, .{ 0, 900 }, .{ 0, 0 }, .{ 1800, 0 } };
        for (1..201) |i| {
            const now = @as(f64, @floatFromInt(i)) * interval;
            const before = s.sample(now);
            try t.expectEqual(before, s.update(targets[i % targets.len], s.size, 10, now, .block));
            for (0..20) |frame| {
                const pose = s.sample(now + interval * @as(f64, @floatFromInt(frame)) / 20);
                try expectUniform(pose, s.size);
                const follower = pose.center + pose.tail_offset;
                try t.expect(follower[0] >= -0.001 and follower[0] <= 1800.001);
                try t.expect(follower[1] >= -0.001 and follower[1] <= 900.001);
            }
        }
        const end = s.update(s.target, s.size, 10, s.began + 1, .block);
        try t.expectEqual(@as(Vec, @splat(0)), end.tail_offset);
        try t.expect(!s.running);
    }
}

test "SmoothCursor uncapped thousand pixel travel has the same peak lag in every direction and shape" {
    const t = std.testing;
    // Equal travel length: vertical and diagonal movement must not use a
    // different offset rule, even for a three-pixel cursor stroke.
    for ([_]Vec{ .{ 1000, 0 }, .{ -1000, 0 }, .{ 0, 1000 }, .{ 0, -1000 }, .{ 600, 800 }, .{ -600, 800 }, .{ 600, -800 }, .{ -600, -800 } }) |step| {
        for ([_]struct { size: Vec, shape: Shape }{
            .{ .size = .{ 19, 42 }, .shape = .block },
            .{ .size = .{ 3, 42 }, .shape = .bar },
            .{ .size = .{ 19, 3 }, .shape = .underline },
        }) |cursor| {
            var s: Self = .{};
            _ = s.update(.{ 0, 0 }, cursor.size, 19, 0, cursor.shape);
            _ = s.update(step, cursor.size, 19, 1, cursor.shape);
            const peak = s.sample(1.066110461);
            try t.expectApproxEqAbs(@as(f32, 88.96315), length(peak.tail_offset), 0.001);
            // The follower stays on the travel line, behind the body.
            try t.expectApproxEqAbs(@as(f32, 0), peak.tail_offset[0] * step[1] - peak.tail_offset[1] * step[0], 0.02);
            try t.expect(@reduce(.Add, peak.tail_offset * step) < 0);
            for (0..221) |ms| {
                const pose = s.sample(1 + @as(f64, @floatFromInt(ms)) / 1000);
                try expectUniform(pose, cursor.size);
                try t.expect(length(pose.tail_offset) <= 88.964);
            }
            try t.expectEqual(@as(Vec, @splat(0)), s.sample(1.221).tail_offset);
        }
    }
}
