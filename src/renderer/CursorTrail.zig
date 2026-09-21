//! Compact nearly straight segments, without dropping the previous frame or
//! a reversal. Sub-millipixel local error stays below 0.032px over 32 points.
const std = @import("std");
pub const Vec = @Vector(2, f32);

fn length(v: Vec) f32 {
    return @sqrt(@reduce(.Add, v * v));
}

pub fn compact(points: []Vec, radii: []f32) u32 {
    var count: usize = 0;
    for (points) |point| {
        while (count >= 2) {
            const a = points[count - 2];
            const b = points[count - 1];
            const delta = point - a;
            const squared = @reduce(.Add, delta * delta);
            if (squared < 0.000001) break;
            const t = @reduce(.Add, (b - a) * delta) / squared;
            // A direction reversal must keep its turning point.
            if (t < 0 or t > 1 or length(b - a - delta * @as(Vec, @splat(t))) > 0.001) break;
            count -= 1;
        }
        points[count] = point;
        count += 1;
    }
    var total: f32 = 0;
    var previous: Vec = @splat(0);
    for (points[0..count], 0..) |point, i| {
        total += length(point - previous);
        radii[i] = total;
        previous = point;
    }
    for (radii[0..count]) |*radius| radius.* = 0.9 - 0.15 * radius.* / @max(total, 0.001);
    return @intCast(count);
}

test "CursorTrail preserves prior frame and corners while collapsing straight history" {
    const t = std.testing;
    var points = [_]Vec{ .{ -1, 0 }, .{ -2, 0 }, .{ -3, 0 }, .{ -4, 0 }, .{ -4, 1 }, .{ -4, 2 } };
    var radii: [points.len]f32 = undefined;
    try t.expectEqual(@as(u32, 3), compact(&points, &radii));
    try t.expectEqual(@as(Vec, .{ -1, 0 }), points[0]);
    try t.expectEqual(@as(Vec, .{ -4, 0 }), points[1]);
    try t.expectEqual(@as(Vec, .{ -4, 2 }), points[2]);
    try t.expectApproxEqAbs(@as(f32, 0.875), radii[0], 0.000001);
    try t.expectApproxEqAbs(@as(f32, 0.75), radii[2], 0.000001);
    var reversed = [_]Vec{ .{ -1, 0 }, .{ -5, 0 }, .{ -3, 0 } };
    try t.expectEqual(@as(u32, 3), compact(&reversed, radii[0..3]));
}

test "CursorTrail taper is independent of straight path sample count" {
    const t = std.testing;
    var low = [_]Vec{ .{ -2, 0 }, .{ -10, 0 } };
    var high = [_]Vec{ .{ -2, 0 }, .{ -3, 0 }, .{ -4, 0 }, .{ -8, 0 }, .{ -10, 0 } };
    var a: [2]f32 = undefined;
    var b: [5]f32 = undefined;
    try t.expectEqual(compact(&low, &a), compact(&high, &b));
    try t.expectEqualSlices(Vec, &low, high[0..2]);
    try t.expectEqualSlices(f32, &a, b[0..2]);
}
