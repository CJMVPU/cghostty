//! Per-frame background row versions. No pixel shadow copy or pixel comparison.
const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Cell = @import("Metal.zig").shaders.CellBg;

alloc: ?Allocator = null,
versions: std.ArrayList(u64) = .empty,
revision: ?u64 = null,
columns: usize = 0,

pub fn deinit(self: *Self) void {
    if (self.alloc) |alloc| self.versions.deinit(alloc);
    self.* = .{};
}

/// Only call on an available frame slot. The buffer is not touched when its
/// background revision is current, even if foreground/cursor data changed.
pub fn sync(self: *Self, alloc: Allocator, buffer: anytype, cells: []const Cell, columns: usize, versions: []const u64, revision: u64) !usize {
    if (self.revision == revision and self.columns == columns and self.versions.items.len == versions.len) return 0;
    std.debug.assert(cells.len == columns * versions.len);
    if (self.alloc == null) self.alloc = alloc;
    const full = self.revision == null or self.columns != columns or self.versions.items.len != versions.len or buffer.len < cells.len;
    // If allocation or contents acquisition fails, force a full retry. A buffer
    // replacement may have succeeded before contents acquisition failed.
    self.revision = null;
    try self.versions.ensureTotalCapacity(alloc, versions.len);
    const dst = try buffer.writable(cells.len);
    var copied: usize = 0;
    if (full) {
        @memcpy(dst, cells);
        copied = cells.len;
    } else {
        var row: usize = 0;
        while (row < versions.len) {
            if (self.versions.items[row] == versions[row]) {
                row += 1;
                continue;
            }
            const start = row;
            while (row < versions.len and self.versions.items[row] != versions[row]) : (row += 1) {}
            @memcpy(dst[start * columns .. row * columns], cells[start * columns .. row * columns]);
            copied += (row - start) * columns;
        }
    }
    self.versions.items.len = versions.len;
    @memcpy(self.versions.items, versions);
    self.columns = columns;
    self.revision = revision;
    return copied * @sizeOf(Cell);
}

const TestBuffer = struct {
    len: usize = 240 * 80,
    data: [240 * 80]Cell = @splat(@splat(0)),
    fail: bool = false,
    pub fn writable(self: *TestBuffer, count: usize) ![]Cell {
        if (self.fail) return error.MetalFailed;
        return self.data[0..count];
    }
};

test "background row upload independent slots retries resize and foreground only frames" {
    const t = std.testing;
    var slots = [_]Self{ .{}, .{}, .{} };
    defer for (&slots) |*slot| slot.deinit();
    var buffers: [3]TestBuffer = @splat(.{});
    var cells: [240 * 80]Cell = @splat(@splat(1));
    var versions: [80]u64 = @splat(1);
    for (&slots, &buffers) |*slot, *buffer| _ = try slot.sync(t.allocator, buffer, &cells, 240, &versions, 1);
    for (0..30) |i| try t.expectEqual(@as(usize, 0), try slots[i % 3].sync(t.allocator, &buffers[i % 3], &cells, 240, &versions, 1));
    var total: usize = 0;
    for (2..32) |revision| {
        const row = revision % 80;
        versions[row] = revision;
        @memset(cells[row * 240 ..][0..240], @splat(@intCast(revision)));
        const i = revision % 3;
        total += try slots[i].sync(t.allocator, &buffers[i], &cells, 240, &versions, revision);
        try t.expectEqualSlices(u8, std.mem.sliceAsBytes(&cells), std.mem.sliceAsBytes(&buffers[i].data));
    }
    std.debug.print("\nWORK_METRIC background_full_bytes={d} row_bytes={d}\n", .{ 30 * cells.len * @sizeOf(Cell), total });
    buffers[0].fail = true;
    versions[0] = 32;
    try t.expectError(error.MetalFailed, slots[0].sync(t.allocator, &buffers[0], &cells, 240, &versions, 32));
    buffers[0].fail = false;
    try t.expectEqual(cells.len * @sizeOf(Cell), try slots[0].sync(t.allocator, &buffers[0], &cells, 240, &versions, 32));
    // Same allocation size but different row layout must still upload in full.
    try t.expectEqual(40 * 240 * @sizeOf(Cell), try slots[0].sync(t.allocator, &buffers[0], cells[0 .. 40 * 240], 120, &versions, 33));
}

test "background row upload follows Contents edits cursor and reset" {
    const t = std.testing;
    var contents: @import("cell.zig").Contents = .{};
    defer contents.deinit(t.allocator);
    try contents.resize(t.allocator, .{ .columns = 10, .rows = 3 });
    var slot: Self = .{};
    defer slot.deinit();
    var buffer: TestBuffer = .{};
    _ = try slot.sync(t.allocator, &buffer, contents.bg_cells, 10, contents.bg_versions, contents.bg_revision);
    contents.clear(1);
    contents.bgCell(1, 4).* = .{ 255, 0, 0, 255 };
    try t.expectEqual(10 * @sizeOf(Cell), try slot.sync(t.allocator, &buffer, contents.bg_cells, 10, contents.bg_versions, contents.bg_revision));
    try t.expectEqualSlices(u8, std.mem.sliceAsBytes(contents.bg_cells), std.mem.sliceAsBytes(buffer.data[0..30]));
    contents.setCursor(.{ .atlas = .grayscale, .grid_pos = .{ 2, 1 }, .color = .{ 255, 255, 255, 255 } }, .block);
    try t.expectEqual(0, try slot.sync(t.allocator, &buffer, contents.bg_cells, 10, contents.bg_versions, contents.bg_revision));
    contents.reset();
    try t.expectEqual(30 * @sizeOf(Cell), try slot.sync(t.allocator, &buffer, contents.bg_cells, 10, contents.bg_versions, contents.bg_revision));
    try t.expectEqualSlices(u8, std.mem.sliceAsBytes(contents.bg_cells), std.mem.sliceAsBytes(buffer.data[0..30]));
}
