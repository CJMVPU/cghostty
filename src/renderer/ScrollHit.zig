//! Coordinates of the last submitted scroll frame, independently synchronized.
const std = @import("std");
const global = @import("../global.zig");
const Self = @This();
mutex: std.Io.Mutex = .init,
data: Data = .{},
pub const Data = struct {
    rects: [4][4]f32 = @splat(@splat(0)),
    offsets: [4][2]f32 = @splat(@splat(0)),
    count: u32 = 0,
    viewport: usize = 0,
    alternate: bool = false,
    epoch: u64 = 0,
    serial: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// Resolve scrolls received by IO after the displayed snapshot. Callers
    /// hold the terminal mutex while supplying the current journal.
    pub fn resolve(self: Data, x: f64, y: f64, journal: @import("../terminal/ScrollState.zig"), cell_width: f64, cell_height: f64, left: f64, top: f64) ?f64 {
        var result = self.unmap(x, y) orelse return null;
        if (!self.alternate) return result;
        if (journal.epoch != self.epoch) return null;
        var serial = self.serial;
        while (serial < journal.serial) : (serial += 1) {
            const event = journal.event(serial) orelse return null;
            const col = (x - left) / cell_width;
            const row = (result - top) / cell_height;
            if (col >= @as(f64, @floatFromInt(event.rect.left)) and col < @as(f64, @floatFromInt(event.rect.right)) and
                row >= @as(f64, @floatFromInt(event.rect.top)) and row < @as(f64, @floatFromInt(event.rect.bottom)))
            {
                const moved = row + @as(f64, @floatFromInt(event.rows));
                if (moved < @as(f64, @floatFromInt(event.rect.top)) or moved >= @as(f64, @floatFromInt(event.rect.bottom))) return null;
                result += @as(f64, @floatFromInt(event.rows)) * cell_height;
            }
        }
        return result;
    }
    pub fn unmap(self: Data, x: f64, y: f64) ?f64 {
        for (self.rects[0..self.count], self.offsets[0..self.count]) |rect, offset| {
            if (x >= rect[0] and x < rect[2] and y >= rect[1] and y < rect[3]) {
                const result = y - offset[0];
                // Outgoing alternate-screen rows no longer exist in the live
                // terminal; do not select or activate a different row instead.
                if (self.alternate and (result < rect[1] or result >= rect[3])) return null;
                return result;
            }
        }
        return y;
    }
};
pub fn read(self: *Self) Data {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    return self.data;
}
pub fn publish(self: *Self, data: Data) void {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    self.data = data;
}

test "scroll hit leaves status and adjacent split fixed" {
    var d: Data = .{ .count = 1, .alternate = true };
    d.rects[0] = .{ 0, 20, 400, 400 };
    d.offsets[0] = .{ 10, 20 };
    try std.testing.expectEqual(@as(?f64, 90), d.unmap(100, 100));
    try std.testing.expectEqual(@as(?f64, 100), d.unmap(500, 100));
    try std.testing.expectEqual(@as(?f64, 410), d.unmap(100, 410));
    try std.testing.expect(d.unmap(100, 25) == null);
    d.alternate = false;
    try std.testing.expectEqual(@as(?f64, 15), d.unmap(100, 25));
}

test "scroll hit follows IO scrolls newer than the displayed frame" {
    const d: Data = .{ .alternate = true };
    var journal: @import("../terminal/ScrollState.zig") = .{};
    journal.record(.{ .left = 0, .top = 1, .right = 20, .bottom = 9 }, -1);
    try std.testing.expectEqual(@as(?f64, 70), d.resolve(10, 90, journal, 10, 20, 0, 0));
    try std.testing.expect(d.resolve(10, 30, journal, 10, 20, 0, 0) == null);
    try std.testing.expectEqual(@as(?f64, 190), d.resolve(10, 190, journal, 10, 20, 0, 0));
}
