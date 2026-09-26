//! Per-frame packed foreground rows. Fixed degenerate cursor slots prevent
//! blinking from shifting the text; variable rows copy only when dirty/moved.
const Self = @This();
const std = @import("std");
const Cell = @import("Metal.zig").shaders.CellText;
const Contents = @import("cell.zig").Contents;
const empty_cursor: Cell = .{ .grid_pos = .{ 0, 0 }, .color = .{ 0, 0, 0, 0 }, .atlas = .grayscale };
const Row = struct { version: u64, offset: usize, len: usize };

alloc: ?std.mem.Allocator = null,
rows: std.ArrayList(Row) = .empty,
revision: ?u64 = null,
foreground_count: usize = 0,
cursors: [2]Cell = .{ empty_cursor, empty_cursor },

pub fn deinit(self: *Self) void {
    if (self.alloc) |alloc| self.rows.deinit(alloc);
    self.* = .{};
}

pub fn invalidate(self: *Self) void {
    self.revision = null;
}

/// Only access an available frame slot. Failure invalidates the slot so a
/// replacement buffer or partially updated metadata is fully retried.
pub fn sync(self: *Self, alloc: std.mem.Allocator, buffer: anytype, contents: *const Contents, revision: u64) !usize {
    if (self.revision == revision) return 0;
    const count: usize = contents.size.rows;
    if (count == 0) {
        self.invalidate();
        self.foreground_count = 0;
        return 0;
    }
    std.debug.assert(contents.fg_rows.len == count + 2);
    var total: usize = 2;
    for (contents.fg_rows[1 .. count + 1]) |row| total = try std.math.add(usize, total, row.items.len);
    const full = self.revision == null or self.rows.items.len != count or buffer.len < total;
    self.revision = null;
    if (self.alloc == null) self.alloc = alloc;
    try self.rows.ensureTotalCapacity(alloc, count);
    const dst = try buffer.writable(total);
    var copied: usize = 0;
    var offset: usize = 1;
    for (contents.fg_rows[1 .. count + 1], contents.bg_versions, 0..) |row, version, i| {
        const next: Row = .{ .version = version, .offset = offset, .len = row.items.len };
        if (full or !std.meta.eql(self.rows.items[i], next)) {
            @memcpy(dst[offset..][0..row.items.len], row.items);
            copied += row.items.len;
        }
        self.rows.allocatedSlice()[i] = next;
        offset += row.items.len;
    }
    for ([_]usize{ 0, count + 1 }, [_]usize{ 0, total - 1 }, 0..) |row, position, i| {
        const next = if (contents.fg_rows[row].items.len == 0) empty_cursor else contents.fg_rows[row].items[0];
        if (full or !std.meta.eql(self.cursors[i], next) or (i == 1 and total != self.foreground_count)) {
            dst[position] = next;
            copied += 1;
        }
        self.cursors[i] = next;
    }
    self.rows.items.len = count;
    self.foreground_count = total;
    self.revision = revision;
    return copied * @sizeOf(Cell);
}

const TestBuffer = struct {
    len: usize = 1024,
    data: [1024]Cell = undefined,
    fail: bool = false,
    pub fn writable(self: *TestBuffer, count: usize) ![]Cell {
        if (self.fail) return error.MetalFailed;
        return self.data[0..count];
    }
};

fn expectContents(buffer: *const TestBuffer, contents: *const Contents, count: usize) !void {
    var offset: usize = 1;
    for (contents.fg_rows[1 .. contents.size.rows + 1]) |row| {
        for (row.items, buffer.data[offset..][0..row.items.len]) |want, actual| try std.testing.expectEqualDeep(want, actual);
        offset += row.items.len;
    }
    try std.testing.expectEqual(offset + 1, count);
    for ([_]usize{ 0, contents.size.rows + 1 }, [_]usize{ 0, count - 1 }) |row, position| {
        try std.testing.expectEqualDeep(if (contents.fg_rows[row].items.len == 0) empty_cursor else contents.fg_rows[row].items[0], buffer.data[position]);
    }
}

test "CellUpload independent slots variable rows cursor updates failure and resize" {
    const t = std.testing;
    var contents: Contents = .{};
    defer contents.deinit(t.allocator);
    try contents.resize(t.allocator, .{ .columns = 20, .rows = 3 });
    const glyph: Cell = .{ .grid_pos = .{ 0, 0 }, .color = .{ 255, 255, 255, 255 }, .atlas = .grayscale };
    for (0..3) |y| for (0..20) |_| {
        var cell = glyph;
        cell.grid_pos[1] = @intCast(y);
        try contents.add(t.allocator, .text, cell);
    };
    var slots = [_]Self{ .{}, .{}, .{} };
    defer for (&slots) |*slot| slot.deinit();
    var buffers: [3]TestBuffer = @splat(.{});
    for (&slots, &buffers) |*slot, *buffer| _ = try slot.sync(t.allocator, buffer, &contents, 0);
    var copied: usize = 0;
    for (1..31) |revision| {
        contents.setCursor(if (revision % 2 == 0) glyph else null, .block);
        const i = revision % 3;
        copied += try slots[i].sync(t.allocator, &buffers[i], &contents, revision);
        try expectContents(&buffers[i], &contents, slots[i].foreground_count);
    }
    try t.expect(copied <= 30 * @sizeOf(Cell));
    std.debug.print("\nWORK_METRIC foreground_full_bytes={d} cursor_bytes={d}\n", .{ 30 * 60 * @sizeOf(Cell), copied });
    // Combining glyphs change packed row length and move following rows.
    contents.clear(1);
    var middle = glyph;
    middle.grid_pos[1] = 1;
    for (0..21) |_| try contents.add(t.allocator, .text, middle);
    for (&slots, &buffers) |*slot, *buffer| {
        _ = try slot.sync(t.allocator, buffer, &contents, 31);
        try expectContents(buffer, &contents, slot.foreground_count);
    }
    contents.clear(1);
    for (0..21) |_| try contents.add(t.allocator, .text, middle);
    try t.expectEqual(21 * @sizeOf(Cell), try slots[0].sync(t.allocator, &buffers[0], &contents, 32));
    buffers[1].fail = true;
    try t.expectError(error.MetalFailed, slots[1].sync(t.allocator, &buffers[1], &contents, 32));
    buffers[1].fail = false;
    try t.expectEqual(63 * @sizeOf(Cell), try slots[1].sync(t.allocator, &buffers[1], &contents, 32));
    try contents.resize(t.allocator, .{ .columns = 10, .rows = 2 });
    _ = try slots[0].sync(t.allocator, &buffers[0], &contents, 33);
    try expectContents(&buffers[0], &contents, slots[0].foreground_count);
}

test "CellUpload handles initial empty contents and buffer growth" {
    const t = std.testing;
    var contents: Contents = .{};
    defer contents.deinit(t.allocator);
    var slot: Self = .{};
    defer slot.deinit();
    var buffer: TestBuffer = .{};
    try t.expectEqual(@as(usize, 0), try slot.sync(t.allocator, &buffer, &contents, 0));
    try t.expectEqual(@as(usize, 0), slot.foreground_count);
    try contents.resize(t.allocator, .{ .columns = 2, .rows = 2 });
    _ = try slot.sync(t.allocator, &buffer, &contents, 1);
    buffer.len = 1; // Model a Metal buffer that must be replaced.
    try t.expectEqual(2 * @sizeOf(Cell), try slot.sync(t.allocator, &buffer, &contents, 2));
    try expectContents(&buffer, &contents, slot.foreground_count);
}
