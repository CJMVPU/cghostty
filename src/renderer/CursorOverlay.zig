//! Conservative cursor-overlay draw planning. Row bounds are measured from the
//! actual glyph quads during upload, so combining marks and overhangs survive.
const std = @import("std");
const shaders = @import("metal/shaders.zig");
pub const Scissor = extern struct { x: c_ulong, y: c_ulong, width: c_ulong, height: c_ulong };
pub const Rect = struct {
    min: [2]f32,
    max: [2]f32,

    pub fn row(cells: []const shaders.CellText, cell_size: [2]f32) ?Rect {
        var result: ?Rect = null;
        for (cells) |cell| {
            if (cell.glyph_size[0] == 0 or cell.glyph_size[1] == 0) continue;
            const lo: [2]f32 = .{
                @as(f32, @floatFromInt(cell.grid_pos[0])) * cell_size[0] + @as(f32, @floatFromInt(cell.bearings[0])),
                (@as(f32, @floatFromInt(cell.grid_pos[1])) + 1) * cell_size[1] - @as(f32, @floatFromInt(cell.bearings[1])),
            };
            const hi: [2]f32 = .{ lo[0] + @as(f32, @floatFromInt(cell.glyph_size[0])), lo[1] + @as(f32, @floatFromInt(cell.glyph_size[1])) };
            if (result) |*r| {
                inline for (0..2) |i| {
                    r.min[i] = @min(r.min[i], lo[i]);
                    r.max[i] = @max(r.max[i], hi[i]);
                }
            } else result = .{ .min = lo, .max = hi };
        }
        return result;
    }
};
pub const Draw = struct { offset: usize = 0, count: usize = 0, scissor: ?Scissor = null };

/// A single contiguous range avoids adding one draw call per candidate row.
/// During scroll, include both unshifted rows and all possible region offsets.
/// This deliberately overselects around split regions instead of clipping a
/// glyph whose center selects a different scroll region than its overhang.
pub fn plan(rows: anytype, foreground_count: usize, u: *const shaders.Uniforms) Draw {
    // Preserve native block/hollow/bar cursor ordering and recoloring exactly.
    if (u.smooth_effect == 0) return .{ .count = foreground_count };
    // Animated bars/underlines do not recolor text; the shader discarded all
    // these fragments and suppressed both static cursor slots anyway.
    if (u.smooth_block == 0) return .{};
    const scissor = clip(u.smooth_bounds_min, u.smooth_bounds_max, u.screen_size) orelse return .{};
    var min_shift: f32 = 0;
    var max_shift: f32 = 0;
    for (u.scroll_offsets[0..u.scroll_count]) |shift| {
        min_shift = @min(min_shift, shift[0]);
        max_shift = @max(max_shift, shift[0]);
    }
    var first: ?usize = null;
    var end: usize = 0;
    for (rows) |row| {
        const rect = row.bounds orelse continue;
        const lo: [2]f32 = .{ rect.min[0] + u.grid_padding[3], rect.min[1] + u.grid_padding[0] + min_shift };
        const hi: [2]f32 = .{ rect.max[0] + u.grid_padding[3], rect.max[1] + u.grid_padding[0] + max_shift };
        // One-pixel conservatism includes float rounding at raster edges.
        if (lo[0] > u.smooth_bounds_max[0] + 1 or hi[0] < u.smooth_bounds_min[0] - 1 or
            lo[1] > u.smooth_bounds_max[1] + 1 or hi[1] < u.smooth_bounds_min[1] - 1) continue;
        if (first == null) first = row.offset;
        end = row.offset + row.len;
    }
    const offset = first orelse return .{};
    return .{ .offset = offset, .count = end - offset, .scissor = scissor };
}

fn clip(lo: [2]f32, hi: [2]f32, screen: [2]f32) ?Scissor {
    var start: [2]c_ulong = undefined;
    var end: [2]c_ulong = undefined;
    inline for (0..2) |i| {
        if (!std.math.isFinite(lo[i]) or !std.math.isFinite(hi[i]) or !std.math.isFinite(screen[i]) or screen[i] <= 0) return null;
        start[i] = @intFromFloat(@floor(std.math.clamp(lo[i], 0, screen[i])));
        end[i] = @intFromFloat(@ceil(std.math.clamp(hi[i], 0, screen[i])));
        if (start[i] >= end[i]) return null;
    }
    return .{ .x = start[0], .y = start[1], .width = end[0] - start[0], .height = end[1] - start[1] };
}

const TestRow = struct { offset: usize, len: usize, bounds: ?Rect };
fn testUniforms() shaders.Uniforms {
    var u = std.mem.zeroes(shaders.Uniforms);
    u.screen_size = .{ 1000, 1000 };
    u.cell_size = .{ 10, 20 };
    u.smooth_effect = 1;
    u.smooth_block = 1;
    u.smooth_bounds_min = .{ 20, 407 };
    u.smooth_bounds_max = .{ 31, 418 };
    return u;
}

test "CursorOverlay selects bounded rows and skips animated bars but preserves native cursors" {
    const t = std.testing;
    var rows: [40]TestRow = undefined;
    for (&rows, 0..) |*row, y| row.* = .{ .offset = 1 + y * 80, .len = 80, .bounds = .{
        .min = .{ 0, @floatFromInt(y * 20) },
        .max = .{ 800, @floatFromInt((y + 1) * 20) },
    } };
    var u = testUniforms();
    const draw = plan(&rows, 3202, &u);
    try t.expectEqual(@as(usize, 1601), draw.offset);
    try t.expectEqual(@as(usize, 80), draw.count);
    try t.expectEqual(@as(c_ulong, 121), draw.scissor.?.width * draw.scissor.?.height);
    std.debug.print("\nWORK_METRIC overlay_full_instances=3202 overlay_instances={d}\n", .{draw.count});
    u.smooth_block = 0;
    try t.expectEqual(@as(usize, 0), plan(&rows, 3202, &u).count);
    u.smooth_effect = 0;
    try t.expectEqual(Draw{ .count = 3202 }, plan(&rows, 3202, &u));
    u.smooth_effect = 1;
    u.smooth_block = 1;
    u.smooth_bounds_min = .{ -10, -10 };
    u.smooth_bounds_max = .{ -1, -1 };
    try t.expectEqual(@as(usize, 0), plan(&rows, 3202, &u).count);
    try t.expectEqual(Scissor{ .x = 0, .y = 0, .width = 12, .height = 21 }, clip(.{ -3.5, -8 }, .{ 11.2, 20.1 }, .{ 100, 100 }).?);
    try t.expectEqual(null, clip(.{ std.math.nan(f32), 0 }, .{ 10, 10 }, .{ 100, 100 }));
}

test "CursorOverlay retains glyph overhangs combining marks and scrolled rows" {
    const t = std.testing;
    const cells = [_]shaders.CellText{
        .{ .grid_pos = .{ 2, 2 }, .glyph_size = .{ 25, 40 }, .bearings = .{ -7, 50 }, .color = @splat(255), .atlas = .grayscale },
        .{ .grid_pos = .{ 2, 2 }, .glyph_size = .{ 8, 8 }, .bearings = .{ -12, 60 }, .color = @splat(255), .atlas = .color },
    };
    const bounds = Rect.row(&cells, .{ 10, 20 }).?;
    try t.expectEqual(Rect{ .min = .{ 8, 0 }, .max = .{ 38, 50 } }, bounds);
    const rows = [_]TestRow{.{ .offset = 81, .len = 2, .bounds = bounds }};
    var u = testUniforms();
    u.grid_padding = .{ 10, 0, 0, 5 };
    u.smooth_bounds_min = .{ 13, 10 };
    u.smooth_bounds_max = .{ 14, 11 };
    try t.expectEqual(@as(usize, 2), plan(&rows, 100, &u).count);
    u.smooth_bounds_min[1] = 70;
    u.smooth_bounds_max[1] = 75;
    try t.expectEqual(@as(usize, 0), plan(&rows, 100, &u).count);
    u.scroll_count = 1;
    u.scroll_offsets[0] = .{ 30, 0 };
    try t.expectEqual(@as(usize, 2), plan(&rows, 100, &u).count);
    u.scroll_offsets[0][0] = -30;
    u.smooth_bounds_min[1] = 0;
    u.smooth_bounds_max[1] = 1;
    try t.expectEqual(@as(usize, 2), plan(&rows, 100, &u).count);
}
