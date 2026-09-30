//! Stable 32-bit C bridge flags. Internal callers use named fields.
const Self = @This();
const std = @import("std");
pub const Flag = enum(c_int) {
    repaint = 1,
    needs_frame = 2,
    geometry_mismatch = 4,
    failed = 8,
    composed = 16,
};
pub const Result = packed struct(u32) {
    repaint: bool = false,
    needs_frame: bool = false,
    geometry_mismatch: bool = false,
    failed: bool = false,
    composed: bool = false,
    reserved: u27 = 0,
    pub fn bits(self: Result) u32 {
        return @bitCast(self);
    }
};
test "compositor result flags match the C protocol and packed fields" {
    try @import("../lib/main.zig").checkGhosttyHEnum(Flag, "GHOSTTY_COMPOSITOR_");
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Result));
    inline for (@typeInfo(Flag).@"enum".fields) |field| {
        var result: Result = .{};
        @field(result, field.name) = true;
        try std.testing.expectEqual(@as(u32, @intCast(field.value)), result.bits());
    }
    try std.testing.expectEqual(@as(u32, 10), (Result{ .needs_frame = true, .failed = true }).bits());
    try std.testing.expectEqual(@as(u32, 6), (Result{ .needs_frame = true, .geometry_mismatch = true }).bits());
}
