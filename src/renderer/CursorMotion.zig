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

/// Requires the draw lock, as do reset and all geometry access.
pub fn sample(self: *Self, enabled: bool, target: ?Target, now: f64) ?Frame {
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
    const pose = self.geometry.update(value.center, value.size, value.timing_width, now, value.shape);
    self.active.store(self.geometry.running, .release);
    return .{ .pose = pose, .effect = self.geometry.effect(now), .time = now };
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

test "CursorMotion disabled geometry and Vim shape changes stop old animation" {
    const t = std.testing;
    var state: Self = .{};
    var target: Target = .{ .center = .{ 0, 0 }, .size = .{ 10, 20 }, .timing_width = 10, .shape = .block };
    _ = state.sample(true, target, 0);
    target.center = .{ 100, 0 };
    _ = state.sample(true, target, 1);
    try t.expect(state.isActive());
    target.shape = .bar;
    target.size = .{ 2, 20 };
    try t.expectEqual(@as(f32, 0), state.sample(true, target, 1.01).?.effect);
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
        // about 2% of the total distance.
        const first = state.geometry.sample(1 + 1.0 / 60.0);
        try t.expectApproxEqAbs(@as(f32, 0.019676), @reduce(.Add, first.center * step) / 1_000_000, 0.00001);
        for (0..261) |ms| {
            const frame = state.sample(true, target, 1 + @as(f64, @floatFromInt(ms)) / 1000).?;
            try t.expectEqual(@as(f32, 1), frame.effect);
            try t.expect(state.isActive());
        }
        const arrived = state.sample(true, target, 1.261).?;
        try t.expectEqual(step, arrived.pose.center);
        try t.expectEqual(@as(u32, 0), arrived.pose.trail_len);
        _ = state.sample(true, target, 1.5);
        try t.expect(!state.isActive());
    }
}
