//! A single immutable accessibility snapshot. All offsets address its UTF-16
//! text, never terminal cells. Sparse ranges avoid a per-byte history map.
const std = @import("std");
const Screen = @import("Screen.zig");
const Cell = @import("page.zig").Cell;
const Coordinate = @import("point.zig").Coordinate;
const Allocator = std.mem.Allocator;

pub const Range = extern struct { location: usize, length: usize };
pub const Snapshot = struct {
    text: [:0]const u8,
    visible: Range,
    selected: []Range,

    pub fn deinit(self: Snapshot, alloc: Allocator) void {
        alloc.free(self.text);
        alloc.free(self.selected);
    }
};

const Marks = struct {
    length: usize = 0,
    visible: ?Range = null,
    selected: std.ArrayList(Range) = .empty,

    fn deinit(self: *Marks, alloc: Allocator) void {
        self.selected.deinit(alloc);
    }
    fn clear(self: *Marks) void {
        self.length = 0;
        self.visible = null;
        self.selected.clearRetainingCapacity();
    }
    fn addRange(self: *Marks, alloc: Allocator, range: Range) !void {
        if (self.selected.items.len > 0) {
            const last = &self.selected.items[self.selected.items.len - 1];
            if (last.location + last.length == range.location) {
                last.length += range.length;
                return;
            }
        }
        try self.selected.append(alloc, range);
    }
    fn add(self: *Marks, alloc: Allocator, n: usize, visible: bool, selected: bool) !void {
        if (visible) {
            if (self.visible) |*range| range.length = self.length + n - range.location else self.visible = .{ .location = self.length, .length = n };
        }
        if (selected) try self.addRange(alloc, .{ .location = self.length, .length = n });
        self.length += n;
    }
    fn merge(self: *Marks, alloc: Allocator, other: *const Marks) !void {
        if (other.visible) |range| {
            if (self.visible) |*v| v.length = self.length + range.location + range.length - v.location else self.visible = .{ .location = self.length + range.location, .length = range.length };
        }
        for (other.selected.items) |range| try self.addRange(alloc, .{
            .location = self.length + range.location,
            .length = range.length,
        });
        self.length += other.length;
    }
};

const Region = struct {
    tl: Coordinate,
    br: Coordinate,
    rectangle: bool = false,

    fn contains(self: Region, x: usize, y: usize, wide: bool) bool {
        if (y < self.tl.y or y > self.br.y) return false;
        const left = if (self.rectangle or y == self.tl.y) self.tl.x else 0;
        const right: usize = if (self.rectangle or y == self.br.y) self.br.x else std.math.maxInt(usize);
        return x <= right and x + @intFromBool(wide) >= left;
    }
    fn newline(self: Region, y: usize) bool {
        return !self.rectangle and y >= self.tl.y and y < self.br.y;
    }
};

/// Caller holds terminal state stable for the entire capture. Plain text follows
/// the formatter's unwrapping and blank trimming rules, while recording only
/// visible/selected spans. Pending blanks are marked before they are emitted so
/// positions remain correct across pages and long runs of empty rows.
pub fn capture(alloc: Allocator, screen: *Screen) Allocator.Error!Snapshot {
    const pages = &screen.pages;
    const top = pages.getTopLeft(.screen);
    const bottom = pages.getBottomRight(.screen).?;
    const viewport: Region = .{
        .tl = pages.pointFromPin(.screen, pages.getTopLeft(.viewport)).?.coord(),
        .br = pages.pointFromPin(.screen, pages.getBottomRight(.viewport).?).?.coord(),
    };
    const selection: ?Region = if (screen.selection) |sel| region: {
        var end = sel.bottomRight(screen);
        // The last column can stand in for a wide character on the next row.
        // Match unwrapped selection semantics, including across page boundaries.
        if (!sel.rectangle and end.rowAndCell().cell.wide == .spacer_head) {
            if (end.down(1)) |next| {
                end = next;
                end.x = 0;
            }
        }
        break :region .{
            .tl = pages.pointFromPin(.screen, sel.topLeft(screen)).?.coord(),
            .br = pages.pointFromPin(.screen, end).?.coord(),
            .rectangle = sel.rectangle,
        };
    } else null;
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    var marks: Marks = .{};
    defer marks.deinit(alloc);
    var spaces: Marks = .{};
    defer spaces.deinit(alloc);
    var newlines: Marks = .{};
    defer newlines.deinit(alloc);
    var rows = top.rowIterator(.right_down, bottom);
    var y: usize = 0;
    while (rows.next()) |pin| : (y += 1) {
        const page = pin.node.page();
        const row = page.getRow(pin.y);
        const cells = page.getCells(row);
        if (!Cell.hasTextAny(cells)) {
            try newlines.add(alloc, 1, viewport.newline(y), if (selection) |s| s.newline(y) else false);
            continue;
        }
        output.writer.splatByteAll('\n', newlines.length) catch return error.OutOfMemory;
        try marks.merge(alloc, &newlines);
        newlines.clear();
        if (!row.wrap_continuation) spaces.clear();
        for (cells, 0..) |*cell, x| {
            if (cell.wide == .spacer_head or cell.wide == .spacer_tail) continue;
            const visible = viewport.contains(x, y, cell.wide == .wide);
            const selected = if (selection) |s| s.contains(x, y, cell.wide == .wide) else false;
            if (!cell.hasText()) {
                try spaces.add(alloc, 1, visible, selected);
                continue;
            }
            output.writer.splatByteAll(' ', spaces.length) catch return error.OutOfMemory;
            try marks.merge(alloc, &spaces);
            spaces.clear();
            var buffer: [4]u8 = undefined;
            const cp = cell.codepoint();
            const n = std.unicode.utf8Encode(cp, &buffer) catch unreachable;
            output.writer.writeAll(buffer[0..n]) catch return error.OutOfMemory;
            var units: usize = if (cp > 0xFFFF) 2 else 1;
            if (cell.content_tag == .codepoint_grapheme) {
                for (page.lookupGrapheme(cell).?) |gcp| {
                    const gn = std.unicode.utf8Encode(gcp, &buffer) catch unreachable;
                    output.writer.writeAll(buffer[0..gn]) catch return error.OutOfMemory;
                    units += if (gcp > 0xFFFF) @as(usize, 2) else 1;
                }
            }
            try marks.add(alloc, units, visible, selected);
        }
        if (!row.wrap) try newlines.add(alloc, 1, viewport.newline(y), if (selection) |s| s.newline(y) else false);
    }
    const text = try output.toOwnedSliceSentinel(0);
    errdefer alloc.free(text);
    return .{
        .text = text,
        .visible = marks.visible orelse .{ .location = marks.length, .length = 0 },
        .selected = try marks.selected.toOwnedSlice(alloc),
    };
}

test "accessibility snapshot matches formatter across wraps, blanks, wide and combining text" {
    const testing = std.testing;
    const Selection = @import("Selection.zig");
    for ([_][]const u8{ "abc", "A\n\n\nB", "123456789abcdef", "中文🙂e\xcc\x81", "1  \n2", "a\n" ** 2000 }) |input| {
        var screen = try Screen.init(testing.io, testing.allocator, .{ .cols = 7, .rows = 3, .max_scrollback_bytes = 1024 * 1024 });
        defer screen.deinit();
        try screen.testWriteString(input);
        const snapshot = try capture(testing.allocator, &screen);
        defer snapshot.deinit(testing.allocator);
        const text = try screen.selectionString(testing.allocator, .{ .sel = Selection.init(screen.pages.getTopLeft(.screen), screen.pages.getBottomRight(.screen).?, false), .trim = false });
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(text, snapshot.text);
    }
}

test "accessibility ranges use full history UTF16 offsets and inclusive selection endpoints" {
    const testing = std.testing;
    const Selection = @import("Selection.zig");
    var screen = try Screen.init(testing.io, testing.allocator, .{ .cols = 8, .rows = 2, .max_scrollback_bytes = 1024 * 1024 });
    defer screen.deinit();
    try screen.testWriteString("old\n😀Z\nend");
    const a = screen.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?;
    try screen.select(Selection.init(a, a, false));
    const snapshot = try capture(testing.allocator, &screen);
    defer snapshot.deinit(testing.allocator);
    try testing.expectEqualStrings("old\n😀Z\nend", snapshot.text);
    try testing.expectEqual(Range{ .location = 4, .length = 7 }, snapshot.visible);
    try testing.expectEqualSlices(Range, &.{.{ .location = 6, .length = 1 }}, snapshot.selected);
}

test "accessibility reversed rectangle preserves disjoint UTF16 ranges" {
    const t = std.testing;
    const Selection = @import("Selection.zig");
    var screen = try Screen.init(t.io, t.allocator, .{ .cols = 8, .rows = 3 });
    defer screen.deinit();
    try screen.testWriteString("a中文z\nb🙂xy\nc123z");
    try screen.select(Selection.init(
        screen.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?,
        screen.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
        true,
    ));
    const snapshot = try capture(t.allocator, &screen);
    defer snapshot.deinit(t.allocator);
    try t.expectEqualStrings("a中文z\nb🙂xy\nc123z", snapshot.text);
    try t.expectEqualSlices(Range, &.{
        .{ .location = 1, .length = 2 },
        .{ .location = 6, .length = 3 },
        .{ .location = 12, .length = 3 },
    }, snapshot.selected);
}

test "accessibility wide spacer endpoints and soft wrap have no phantom characters" {
    const t = std.testing;
    const Selection = @import("Selection.zig");
    var screen = try Screen.init(t.io, t.allocator, .{ .cols = 4, .rows = 3 });
    defer screen.deinit();
    try screen.testWriteString("abc🙂e\xcc\x81z");
    for ([_]Coordinate{ .{ .x = 3, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } }) |coord| {
        const pin = screen.pages.pin(.{ .screen = coord }).?;
        try screen.select(Selection.init(pin, pin, false));
        const snapshot = try capture(t.allocator, &screen);
        defer snapshot.deinit(t.allocator);
        try t.expectEqualStrings("abc🙂e\xcc\x81z", snapshot.text);
        try t.expectEqualSlices(Range, &.{.{ .location = 3, .length = 2 }}, snapshot.selected);
    }
}

test "accessibility visible range follows scrollback and empty screens" {
    const t = std.testing;
    var screen = try Screen.init(t.io, t.allocator, .{ .cols = 8, .rows = 2, .max_scrollback_bytes = 1024 * 1024 });
    defer screen.deinit();
    {
        const snapshot = try capture(t.allocator, &screen);
        defer snapshot.deinit(t.allocator);
        try t.expectEqualStrings("", snapshot.text);
        try t.expectEqual(Range{ .location = 0, .length = 0 }, snapshot.visible);
        try t.expectEqual(@as(usize, 0), snapshot.selected.len);
    }
    try screen.testWriteString("old\n😀Z\nend");
    screen.pages.scroll(.top);
    const snapshot = try capture(t.allocator, &screen);
    defer snapshot.deinit(t.allocator);
    try t.expectEqualStrings("old\n😀Z\nend", snapshot.text);
    try t.expectEqual(Range{ .location = 0, .length = 7 }, snapshot.visible);
}
