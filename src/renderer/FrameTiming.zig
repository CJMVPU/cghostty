//! Convert display-link media time to the renderer's awake clock without
//! confusing the animation target's update time with its presentation sample.
const std = @import("std");
const Self = @This();
pub extern "c" fn CACurrentMediaTime() f64;
update: f64,
presentation: f64,

pub fn init(awake_now: f64, media_now: f64, target: f64) Self {
    const delta = target - media_now;
    return .{ .update = awake_now, .presentation = awake_now + if (std.math.isFinite(delta)) @max(0, delta) else 0 };
}

pub fn nanoseconds(seconds: f64) u64 {
    if (!std.math.isFinite(seconds) or seconds <= 0 or seconds >= 1e10) return 0;
    return @intFromFloat(seconds * std.time.ns_per_s);
}

test "FrameTiming maps media presentation time without moving animation start" {
    const timing = Self.init(10, 1000, 1000.016);
    try std.testing.expectEqual(@as(f64, 10), timing.update);
    try std.testing.expectApproxEqAbs(@as(f64, 10.016), timing.presentation, 0.000001);
    try std.testing.expectEqual(@as(f64, 10), Self.init(10, 1000, 999).presentation);
    try std.testing.expectEqual(@as(f64, 10), Self.init(10, 1000, std.math.nan(f64)).presentation);
}
