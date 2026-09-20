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
    return .{ .pose = pose, .effect = self.geometry.effect(now) };
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
