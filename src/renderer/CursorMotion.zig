//! Cursor animation lifecycle. Geometry is draw-lock-owned; cross-thread
//! invalidation and scheduling observations use only the atomic boundary.
const Self = @This();
const std = @import("std");
pub const Geometry = @import("SmoothCursor.zig");

geometry: Geometry = .{},
reset_pending: std.atomic.Value(bool) = .init(false),
active: std.atomic.Value(bool) = .init(false),

pub const Target = struct {
    center: Geometry.Vec,
    size: Geometry.Vec,
    timing_width: f32,
    shape: Geometry.Shape,
    mode: Geometry.Mode = .responsive,
};

pub const Frame = struct {
    pose: Geometry.Sample,
    effect: f32,
    time: f64,
};

/// May be called without the draw lock. Actual geometry resets at sampling.
pub fn invalidate(self: *Self) void {
    self.reset_pending.store(true, .release);
    self.active.store(false, .release);
}

pub fn isActive(self: *const Self) bool {
    return !self.reset_pending.load(.acquire) and self.active.load(.acquire);
}

/// Requires the draw lock. Target changes, geometry and history share the
/// presentation timeline: a short move must not finish before its first frame.
pub fn sample(self: *Self, enabled: bool, target: ?Target, presentation: f64) ?Frame {
    if (self.reset_pending.swap(false, .acq_rel)) self.reset();
    if (!enabled) {
        self.reset();
        return null;
    }
    // DECTCEM/blink hides drawing, not the continuous motion state.
    const value = target orelse {
        self.geometry.hide();
        self.active.store(false, .release);
        return null;
    };
    if (@reduce(.Or, value.size <= @as(Geometry.Vec, @splat(0)))) {
        self.reset();
        return null;
    }
    if (self.geometry.mode != value.mode) {
        self.geometry.reset();
        self.geometry.mode = value.mode;
    }
    // A changing display prediction must not rewind an already submitted pose.
    const time = if (self.geometry.history_len > 0)
        @max(presentation, self.geometry.history[self.geometry.history_len - 1].time)
    else
        presentation;
    const pose = self.geometry.update(value.center, value.size, value.timing_width, time, value.shape);
    self.active.store(self.geometry.running and (time < self.geometry.hold_until + Geometry.recovery_duration or pose.trail_len > 0), .release);
    return .{ .pose = pose, .effect = self.geometry.effect(time), .time = time };
}

/// Called only after successful frame encoding/submission, under draw_mutex.
pub fn recordFrame(self: *Self, frame: Frame) void {
    self.geometry.recordFrame(frame.time, frame.pose);
}

pub fn reset(self: *Self) void {
    self.geometry.reset();
    self.active.store(false, .release);
}

test "CursorMotion hide preserves repeated movement but invalidation snaps on return" {
    const t = std.testing;
    var state: Self = .{};
    var target: Target = .{ .center = .{ 0, 0 }, .size = .{ 10, 20 }, .timing_width = 10, .shape = .block };
    _ = state.sample(true, target, 0);
    target.center = .{ 100, 100 };
    _ = state.sample(true, target, 1);
    const before = state.geometry.sample(1.04);
    try t.expect(state.sample(true, null, 1.04) == null);
    try t.expect(!state.isActive());
    target.center = .{ 200, 100 };
    const resumed = state.sample(true, target, 1.04).?;
    try t.expectEqual(before, resumed.pose);
    try t.expect(state.isActive());
    state.invalidate();
    try t.expect(!state.isActive());
    const snapped = state.sample(true, target, 1.05).?;
    try t.expectEqual(@as(f32, 0), snapped.effect);
    try t.expect(!state.isActive());
}

test "CursorMotion Vim shape changes continue drawing while disabled or invalid geometry stops" {
    const t = std.testing;
    var state: Self = .{};
    var target: Target = .{ .center = .{ 0, 0 }, .size = .{ 10, 20 }, .timing_width = 10, .shape = .block };
    _ = state.sample(true, target, 0);
    target.center = .{ 100, 0 };
    _ = state.sample(true, target, 1);
    try t.expect(state.isActive());
    target.shape = .bar;
    target.size = .{ 2, 20 };
    const before = state.geometry.sample(1.01);
    const changed = state.sample(true, target, 1.01).?;
    try t.expectEqual(before, changed.pose);
    try t.expectEqual(@as(f32, 1), changed.effect);
    try t.expect(state.isActive());
    target.center = .{ 120, 0 };
    _ = state.sample(true, target, 1.02);
    try t.expect(state.isActive());
    try t.expect(state.sample(false, target, 1.03) == null);
    try t.expect(!state.isActive());
    _ = state.sample(true, target, 2);
    target.center = .{ 140, 0 };
    _ = state.sample(true, target, 3);
    _ = state.sample(true, target, 4);
    try t.expect(!state.isActive());
    target.size = .{ 0, 20 };
    try t.expect(state.sample(true, target, 4.1) == null);
}

test "CursorMotion invalidation clears submitted history after frame failure" {
    const t = std.testing;
    var state: Self = .{};
    var target: Target = .{ .center = .{ 0, 0 }, .size = .{ 19, 42 }, .timing_width = 19, .shape = .block };
    state.recordFrame(state.sample(true, target, 0).?);
    target.center = .{ 1000, 0 };
    state.recordFrame(state.sample(true, target, 1).?);
    const moving = state.sample(true, target, 1.016).?;
    try t.expect(moving.pose.trail_len > 0);
    state.recordFrame(moving);
    state.invalidate();
    try t.expect(!state.isActive());
    const recovered = state.sample(true, target, 1.032).?;
    try t.expectEqual(target.center, recovered.pose.center);
    try t.expectEqual(@as(u32, 0), recovered.pose.trail_len);
    try t.expectEqual(@as(f32, 0), recovered.effect);
    state.recordFrame(recovered);
    target.center = .{ 1000, 1000 };
    _ = state.sample(true, target, 2);
    const next = state.sample(true, target, 2.016).?;
    try t.expectEqual(@as(u32, 1), next.pose.trail_len);
    try t.expectEqual(recovered.pose.center, next.pose.center + next.pose.trail[0]);
}

test "CursorMotion long travel starts visible and keeps rendering through follower arrival" {
    const t = std.testing;
    for ([_]Geometry.Vec{ .{ 1000, 0 }, .{ 0, 1000 }, .{ 600, 800 } }) |step| {
        var state: Self = .{};
        var target: Target = .{ .center = .{ 0, 0 }, .size = .{ 19, 42 }, .timing_width = 19, .shape = .block };
        _ = state.sample(true, target, 0);
        target.center = step;
        const start = state.sample(true, target, 1).?;
        try t.expectEqual(@as(Geometry.Vec, .{ 0, 0 }), start.pose.center);
        try t.expectEqual(@as(f32, 1), start.effect);
        // Long travel accelerates from rest: the first 60Hz frame travels
        // about 3% of the total distance.
        const first = state.geometry.sample(1 + 1.0 / 60.0);
        try t.expectApproxEqAbs(@as(f32, 0.030292), @reduce(.Add, first.center * step) / 1_000_000, 0.00001);
        for (0..201) |ms| {
            const frame = state.sample(true, target, 1 + @as(f64, @floatFromInt(ms)) / 1000).?;
            try t.expectEqual(@as(f32, 1), frame.effect);
            try t.expect(state.isActive());
        }
        const arrived = state.sample(true, target, 1.201).?;
        try t.expectEqual(step, arrived.pose.center);
        try t.expectEqual(@as(u32, 0), arrived.pose.trail_len);
        _ = state.sample(true, target, 1.5);
        try t.expect(!state.isActive());
    }
}

test "CursorMotion presets propagate through hide disable invalidation and mode changes" {
    const t = std.testing;
    var state: Self = .{};
    var target: Target = .{ .center = .{ 0, 0 }, .size = .{ 10, 20 }, .timing_width = 10, .shape = .block, .mode = .instant };
    state.recordFrame(state.sample(true, target, 0).?);
    target.center = .{ 1000, 0 };
    const instant = state.sample(true, target, 1).?;
    try t.expectEqual(target.center, instant.pose.center);
    try t.expect(instant.pose.trail_len > 0);
    state.recordFrame(instant);
    try t.expect(state.sample(true, null, 1.01) == null);
    target.center = .{ 80, 20 };
    try t.expectEqual(target.center, state.sample(true, target, 1.02).?.pose.center);
    state.invalidate();
    const recovered = state.sample(true, target, 1.03).?;
    try t.expectEqual(@as(u32, 0), recovered.pose.trail_len);
    try t.expectEqual(Geometry.Mode.instant, state.geometry.mode);
    try t.expect(state.sample(false, target, 1.04) == null);
    try t.expect(!state.isActive());
    target.mode = .responsive;
    _ = state.sample(true, target, 2);
    target.center = .{ 1000, 40 };
    _ = state.sample(true, target, 3);
    try t.expectApproxEqAbs(@as(f32, 0.160), state.geometry.duration, 0.000001);
    target.mode = .instant;
    const changed = state.sample(true, target, 3.01).?;
    try t.expectEqual(target.center, changed.pose.center);
    try t.expectEqual(@as(u32, 0), changed.pose.trail_len);
    target.center = .{ 0, 60 };
    _ = state.sample(true, target, 4);
    try t.expectApproxEqAbs(@as(f32, 0), state.geometry.duration, 0.000001);
}

test "CursorMotion target and geometry use the same presentation timeline" {
    var state: Self = .{};
    var target: Target = .{ .center = .{ 0, 0 }, .size = .{ 10, 20 }, .timing_width = 10, .shape = .block };
    _ = state.sample(true, target, 0);
    target.center = .{ 100, 0 };
    const frame = state.sample(true, target, 1.016).?;
    try std.testing.expectEqual(@as(f64, 1.016), state.geometry.began);
    try std.testing.expectEqual(@as(f32, 0), frame.pose.center[0]);
    try std.testing.expectEqual(@as(f64, 1.016), frame.time);
    const next = state.sample(true, target, 1.032).?;
    try std.testing.expect(next.pose.center[0] > 0);
    try std.testing.expect(next.pose.center[0] < 100);
    try std.testing.expectEqual(@as(f64, 1.016), state.geometry.began);
}

test "CursorMotion settles at presentation time without truncating a submitted trail" {
    const t = std.testing;
    var state: Self = .{};
    var target: Target = .{ .center = .{ 0, 0 }, .size = .{ 10, 20 }, .timing_width = 10, .shape = .block };
    state.recordFrame(state.sample(true, target, 0).?);
    target.center = .{ 100, 0 };
    state.recordFrame(state.sample(true, target, 1.04).?);
    // A late frame must drain its visible history before the clock can pause.
    const late = state.sample(true, target, 1.30).?;
    try t.expect(late.pose.trail_len > 0);
    try t.expect(state.isActive());
    state.recordFrame(late);
    const settled = state.sample(true, target, 1.45).?;
    try t.expect(!state.geometry.running);
    try t.expectEqual(target.center, settled.pose.center);
    try t.expectEqual(@as(f32, 0), settled.effect);
    try t.expectEqual(@as(u32, 0), settled.pose.trail_len);
    try t.expect(!state.isActive());
}

test "CursorMotion short move keeps visible intermediate positions with presentation lead" {
    const t = std.testing;
    var state: Self = .{};
    var target: Target = .{ .center = .{ 0, 0 }, .size = .{ 10, 20 }, .timing_width = 10, .shape = .block };
    state.recordFrame(state.sample(true, target, 0.0415).?);
    target.center = .{ 10, 0 };
    const first = state.sample(true, target, 1.0415).?;
    try t.expect(first.pose.center[0] < 10);
    state.recordFrame(first);
    const middle = state.sample(true, target, 1.049833).?;
    try t.expect(middle.pose.center[0] > first.pose.center[0]);
    try t.expect(middle.pose.center[0] < 10);
    state.recordFrame(middle);
    const arrived = state.sample(true, target, 1.074833).?;
    try t.expectEqual(target.center, arrived.pose.center);
}

test "CursorMotion presentation lead does not change repeat movement at 60 and 120Hz" {
    const t = std.testing;
    for ([_]f64{ 60, 120 }) |hz| {
        for ([_]f64{ 0, 0.016, 0.0415, 0.083 }) |lead| {
            var immediate: Self = .{};
            var delayed: Self = .{};
            var target: Target = .{ .center = .{ 0, 0 }, .size = .{ 10, 20 }, .timing_width = 10, .shape = .block };
            immediate.recordFrame(immediate.sample(true, target, 0).?);
            delayed.recordFrame(delayed.sample(true, target, lead).?);
            var previous: f32 = 0;
            for (0..36) |i| {
                const now = 1 + @as(f64, @floatFromInt(i)) / hz;
                // Repeated keys, stationary frames, and a Chinese-width geometry
                // transition all retain the same motion under a shifted clock.
                if (i % 2 == 0) target.center[0] += 10;
                if (i == 12) target.size[0] = 20;
                const expected = immediate.sample(true, target, now).?;
                const actual = delayed.sample(true, target, now + lead).?;
                try t.expectApproxEqAbs(expected.pose.center[0], actual.pose.center[0], 0.001);
                try t.expectApproxEqAbs(expected.pose.size[0], actual.pose.size[0], 0.001);
                try t.expect(actual.pose.center[0] >= previous);
                try t.expect(actual.pose.center[0] <= target.center[0]);
                previous = actual.pose.center[0];
                immediate.recordFrame(expected);
                delayed.recordFrame(actual);
                // A regressing prediction for unchanged content cannot rewind.
                const repeated = delayed.sample(true, target, now + lead - 0.0065).?;
                try t.expectEqual(actual.pose.center, repeated.pose.center);
            }
            const stopped = delayed.sample(true, target, 3).?;
            delayed.recordFrame(stopped);
            _ = delayed.sample(true, target, 3.5);
            try t.expect(!delayed.isActive());
        }
    }
}

test "CursorMotion instant presentation remains immediate and mode switch resets history" {
    const t = std.testing;
    var state: Self = .{};
    var target: Target = .{ .center = .{ 0, 0 }, .size = .{ 10, 20 }, .timing_width = 10, .shape = .block };
    state.recordFrame(state.sample(true, target, 0.0415).?);
    target.center = .{ 10, 0 };
    state.recordFrame(state.sample(true, target, 1.0415).?);
    target.mode = .instant;
    target.center = .{ 20, 0 };
    const switched = state.sample(true, target, 1.049833).?;
    try t.expectEqual(target.center, switched.pose.center);
    try t.expectEqual(@as(u32, 0), switched.pose.trail_len);
    state.recordFrame(switched);
    target.center = .{ 30, 0 };
    try t.expectEqual(target.center, state.sample(true, target, 1.058166).?.pose.center);
}
