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

/// Constant-size identity for a text/range snapshot. Mutation epochs are
/// independent of renderer dirty bits; endpoints also detect direct viewport
/// scrolling and tracked selection movement without scanning any history.
pub const Tracker = struct {
    key: ?Key = null,
    revision: u64 = 0,
    text_key: ?@import("SnapshotIdentity.zig").ContentView = null,
    text_revision: u64 = 0,
    index: ?Index = null,

    pub fn deinit(self: *Tracker, alloc: Allocator) void {
        if (self.index) |*index| index.deinit(alloc);
    }

    /// A zero previous revision always requests text, including for a new reader.
    /// Only commit the cached index after every output allocation succeeds.
    pub fn read(self: *Tracker, alloc: Allocator, term: *@import("Terminal.zig"), previous: u64) !?Update {
        const revision = self.current(term);
        if (previous != 0 and previous == revision) return null;
        var key = self.key.?.content;
        // Viewport position does not change document text or row coordinates.
        key.viewport = key.top;
        if (previous == 0 or self.index == null or !std.meta.eql(self.text_key.?, key)) {
            var index: Index = .{};
            const snapshot = try captureIndexed(alloc, term.screens.active, &index);
            if (self.index) |*old| old.deinit(alloc);
            self.index = index;
            self.text_key = key;
            self.text_revision = revision;
            return .{ .text = snapshot.text, .visible = snapshot.visible, .selected = snapshot.selected, .revision = revision, .text_revision = revision };
        }
        const ranges = try self.index.?.query(alloc, term.screens.active);
        return .{ .text = null, .visible = ranges.visible, .selected = ranges.selected, .revision = revision, .text_revision = self.text_revision };
    }

    pub fn current(self: *Tracker, term: *const @import("Terminal.zig")) u64 {
        const key = Key.read(term);
        if (self.key == null or !std.meta.eql(self.key.?, key)) {
            self.key = key;
            self.revision +%= 1;
            if (self.revision == 0) self.revision = 1;
        }
        return self.revision;
    }

    pub const Key = struct {
        content: @import("SnapshotIdentity.zig").ContentView,
        selection: @import("SnapshotIdentity.zig").Selection,
        pub fn read(term: *const @import("Terminal.zig")) Key {
            return .{ .content = .read(term), .selection = .read(term.screens.active) };
        }
    };
};

pub const Update = struct {
    text: ?[:0]const u8,
    visible: Range,
    selected: []Range,
    revision: u64,
    text_revision: u64,

    pub fn deinit(self: Update, alloc: Allocator) void {
        if (self.text) |text| alloc.free(text);
        alloc.free(self.selected);
    }
};

/// One span per contiguous emitted part of a row, rather than per cell/byte.
/// Deferred whitespace carries its source coordinates until actually emitted.
const Span = struct {
    row: usize,
    x0: usize,
    x1: usize, // Exclusive; zero denotes a hard newline.
    offset: usize = 0,
    length: usize = 0,
};

const Index = struct {
    spans: []Span = &.{},
    length: usize = 0,

    fn deinit(self: *Index, alloc: Allocator) void {
        alloc.free(self.spans);
    }

    fn firstRow(self: Index, row: usize) usize {
        var lo: usize = 0;
        var hi = self.spans.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.spans[mid].row < row) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn range(screen: *Screen, span: Span, region: Region) ?Range {
        if (span.x1 == 0) return if (region.newline(span.row))
            .{ .location = span.offset, .length = span.length }
        else
            null;
        const left = if (region.rectangle or span.row == region.tl.y) region.tl.x else 0;
        const right: usize = if (region.rectangle or span.row == region.br.y) region.br.x else std.math.maxInt(usize);
        if (left <= span.x0 and right >= span.x1 - 1)
            return .{ .location = span.offset, .length = span.length };
        if (left >= span.x1 or right < span.x0) return null;
        // Only partial row spans need to inspect cell widths and graphemes.
        const pin = screen.pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(span.row) } }).?;
        const page = pin.node.page();
        const cells = page.getCells(page.getRow(pin.y));
        var offset = span.offset;
        var result: ?Range = null;
        for (cells[span.x0..span.x1], span.x0..) |*cell, x| {
            if (cell.wide == .spacer_head or cell.wide == .spacer_tail) continue;
            const units = cellUnits(page, cell);
            if (region.contains(x, span.row, cell.wide == .wide)) {
                if (result) |*r| r.length += units else result = .{ .location = offset, .length = units };
            }
            offset += units;
        }
        return result;
    }

    fn query(self: Index, alloc: Allocator, screen: *Screen) !struct { visible: Range, selected: []Range } {
        const regions = Regions.read(screen);
        var visible: ?Range = null;
        for (self.spans[self.firstRow(regions.viewport.tl.y)..]) |span| {
            if (span.row > regions.viewport.br.y) break;
            if (range(screen, span, regions.viewport)) |r| {
                if (visible) |*v| {
                    const end = @max(v.location + v.length, r.location + r.length);
                    v.location = @min(v.location, r.location);
                    v.length = end - v.location;
                } else visible = r;
            }
        }
        var selected: std.ArrayList(Range) = .empty;
        defer selected.deinit(alloc);
        if (regions.selection) |region| {
            for (self.spans[self.firstRow(region.tl.y)..]) |span| {
                if (span.row > region.br.y) break;
                if (range(screen, span, region)) |r| try selected.append(alloc, r);
            }
        }
        // Source row order and output order can differ for deferred whitespace.
        std.mem.sort(Range, selected.items, {}, struct {
            fn less(_: void, a: Range, b: Range) bool {
                return a.location < b.location;
            }
        }.less);
        var count: usize = 0;
        for (selected.items) |r| {
            if (count > 0 and selected.items[count - 1].location + selected.items[count - 1].length == r.location) {
                selected.items[count - 1].length += r.length;
            } else {
                selected.items[count] = r;
                count += 1;
            }
        }
        selected.shrinkRetainingCapacity(count);
        return .{ .visible = visible orelse .{ .location = self.length, .length = 0 }, .selected = try selected.toOwnedSlice(alloc) };
    }
};

fn cellUnits(page: anytype, cell: *const Cell) usize {
    var units: usize = if (cell.codepoint() > 0xFFFF) 2 else 1;
    if (cell.content_tag == .codepoint_grapheme) {
        for (page.lookupGrapheme(cell).?) |cp| units += if (cp > 0xFFFF) @as(usize, 2) else 1;
    }
    return units;
}

const Marks = struct {
    indexed: bool = false,
    spans: std.ArrayList(Span) = .empty,
    length: usize = 0,
    visible: ?Range = null,
    selected: std.ArrayList(Range) = .empty,

    fn deinit(self: *Marks, alloc: Allocator) void {
        self.selected.deinit(alloc);
        self.spans.deinit(alloc);
    }
    fn clear(self: *Marks) void {
        self.length = 0;
        self.visible = null;
        self.selected.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
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
    fn addSpan(self: *Marks, alloc: Allocator, span: Span) !void {
        if (!self.indexed) return;
        if (self.spans.items.len > 0) {
            const last = &self.spans.items[self.spans.items.len - 1];
            if (last.row == span.row and last.x1 != 0 and last.x1 == span.x0 and
                last.offset + last.length == span.offset)
            {
                last.x1 = span.x1;
                last.length += span.length;
                return;
            }
        }
        try self.spans.append(alloc, span);
    }
    fn add(self: *Marks, alloc: Allocator, n: usize, visible: bool, selected: bool, source: Span) !void {
        var span = source;
        span.offset = self.length;
        span.length = n;
        try self.addSpan(alloc, span);
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
        for (other.spans.items) |source| {
            var span = source;
            span.offset += self.length;
            try self.addSpan(alloc, span);
        }
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

const Regions = struct {
    viewport: Region,
    selection: ?Region,
    fn read(screen: *Screen) Regions {
        const pages = &screen.pages;
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
        return .{ .viewport = viewport, .selection = selection };
    }
};

/// Caller holds terminal state stable for the entire capture. Plain text follows
/// the formatter's unwrapping and blank trimming rules, while recording only
/// visible/selected spans. Pending blanks are marked before they are emitted so
/// positions remain correct across pages and long runs of empty rows.
pub fn capture(alloc: Allocator, screen: *Screen) Allocator.Error!Snapshot {
    return captureIndexed(alloc, screen, null);
}

fn captureIndexed(alloc: Allocator, screen: *Screen, index: ?*Index) Allocator.Error!Snapshot {
    const pages = &screen.pages;
    const top = pages.getTopLeft(.screen);
    const bottom = pages.getBottomRight(.screen).?;
    const regions = Regions.read(screen);
    const viewport = regions.viewport;
    const selection = regions.selection;
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    var marks: Marks = .{ .indexed = index != null };
    defer marks.deinit(alloc);
    var spaces: Marks = .{ .indexed = index != null };
    defer spaces.deinit(alloc);
    var newlines: Marks = .{ .indexed = index != null };
    defer newlines.deinit(alloc);
    var rows = top.rowIterator(.right_down, bottom);
    var y: usize = 0;
    while (rows.next()) |pin| : (y += 1) {
        const page = pin.node.page();
        const row = page.getRow(pin.y);
        const cells = page.getCells(row);
        if (!Cell.hasTextAny(cells)) {
            try newlines.add(alloc, 1, viewport.newline(y), if (selection) |s| s.newline(y) else false, .{ .row = y, .x0 = 0, .x1 = 0 });
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
                try spaces.add(alloc, 1, visible, selected, .{ .row = y, .x0 = x, .x1 = x + 1 });
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
            try marks.add(alloc, units, visible, selected, .{ .row = y, .x0 = x, .x1 = @min(cells.len, x + 1 + @intFromBool(cell.wide == .wide)) });
        }
        if (!row.wrap) try newlines.add(alloc, 1, viewport.newline(y), if (selection) |s| s.newline(y) else false, .{ .row = y, .x0 = 0, .x1 = 0 });
    }
    const text = try output.toOwnedSliceSentinel(0);
    errdefer alloc.free(text);
    const selected = try marks.selected.toOwnedSlice(alloc);
    errdefer alloc.free(selected);
    if (index) |value| {
        const spans = try marks.spans.toOwnedSlice(alloc);
        std.mem.sort(Span, spans, {}, struct {
            fn less(_: void, a: Span, b: Span) bool {
                return a.row < b.row or (a.row == b.row and a.offset < b.offset);
            }
        }.less);
        value.* = .{ .spans = spans, .length = marks.length };
    }
    return .{
        .text = text,
        .visible = marks.visible orelse .{ .location = marks.length, .length = 0 },
        .selected = selected,
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

test "accessibility tracker survives renderer dirty resets and detects all snapshot inputs" {
    const t = std.testing;
    var term = try @import("Terminal.zig").init(t.io, t.allocator, .{ .cols = 10, .rows = 2, .max_scrollback_bytes = 1024 * 1024 });
    defer term.deinit(t.allocator);
    var tracker: Tracker = .{};
    var revision = tracker.current(&term);
    try t.expectEqual(revision, tracker.current(&term));
    var stream = term.vtStream();
    defer stream.deinit();
    // Overwrite, erase, soft-wrap, scroll, alternate screen and reset all change
    // the snapshot even if a renderer has already consumed the dirty flags.
    for ([_][]const u8{ "中文🙂", "\rX", "\x1b[2K", "012345678901", "\r\nnext\r\nlast", "\x1b[?1049h", "ALT", "\x1b[?1049l", "\x1bc" }) |input| {
        stream.nextSlice(input);
        var render: @import("render.zig").RenderState = .empty;
        defer render.deinit(t.allocator);
        try render.update(t.allocator, &term);
        const next = tracker.current(&term);
        try t.expect(next > revision);
        try t.expectEqual(next, tracker.current(&term));
        revision = next;
    }
    try term.printString("old\nvisible\nlast");
    revision = tracker.current(&term);
    term.screens.active.pages.scroll(.top);
    try t.expect(tracker.current(&term) > revision);
    revision = tracker.current(&term);
    const pin = term.screens.active.pages.getTopLeft(.screen);
    try term.screens.active.select(@import("Selection.zig").init(pin, pin, false));
    try t.expect(tracker.current(&term) > revision);
    revision = tracker.current(&term);
    term.screens.active.clearSelection();
    try t.expect(tracker.current(&term) > revision);
    revision = tracker.current(&term);
    try term.resize(t.allocator, .{ .cols = 8, .rows = 3 });
    try t.expect(tracker.current(&term) > revision);
    revision = tracker.current(&term);
    term.setScrollbackMaxLines(0);
    try t.expect(tracker.current(&term) > revision);
}

test "input document maps single cells to complete UTF16 graphemes" {
    const t = std.testing;
    const Selection = @import("Selection.zig");
    var screen = try Screen.init(t.io, t.allocator, .{ .cols = 8, .rows = 2 });
    defer screen.deinit();
    try screen.testWriteString("a中🙂e\xcc\x81z");
    const expected = [_]Range{
        .{ .location = 0, .length = 1 }, .{ .location = 1, .length = 1 },
        .{ .location = 1, .length = 1 }, .{ .location = 2, .length = 2 },
        .{ .location = 2, .length = 2 }, .{ .location = 4, .length = 2 },
        .{ .location = 6, .length = 1 },
    };
    for (expected, 0..) |range, x| {
        const pin = screen.pages.pin(.{ .screen = .{ .x = @intCast(x), .y = 0 } }).?;
        try screen.select(Selection.init(pin, pin, false));
        const snapshot = try capture(t.allocator, &screen);
        defer snapshot.deinit(t.allocator);
        try t.expectEqualSlices(Range, &.{range}, snapshot.selected);
    }
}

test "input document retains selection coordinates outside the viewport" {
    const t = std.testing;
    const Selection = @import("Selection.zig");
    var screen = try Screen.init(t.io, t.allocator, .{ .cols = 8, .rows = 2, .max_scrollback_bytes = 1024 * 1024 });
    defer screen.deinit();
    try screen.testWriteString("old\n😀Z\nend");
    try screen.select(Selection.init(screen.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?, screen.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?, false));
    const snapshot = try capture(t.allocator, &screen);
    defer snapshot.deinit(t.allocator);
    try t.expectEqual(Range{ .location = 4, .length = 7 }, snapshot.visible);
    try t.expectEqualSlices(Range, &.{.{ .location = 1, .length = 6 }}, snapshot.selected);
}

test "optimization probe full history input query" {
    if (@import("builtin").mode == .Debug) return error.SkipZigTest;
    const t = std.testing;
    for ([_]usize{ 10_000, 30_000 }) |lines| {
        var term = try @import("Terminal.zig").init(t.io, t.allocator, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 128 * 1024 * 1024 });
        defer term.deinit(t.allocator);
        const screen = term.screens.active;
        for (0..lines) |_| try term.printString("row abc 中🙂 e\xcc\x81\n");
        var times: [5]i128 = undefined;
        var bytes: usize = 0;
        var mutex: std.Io.Mutex = .init;
        for (0..times.len + 1) |i| {
            const start = std.Io.Timestamp.now(t.io, .awake);
            mutex.lockUncancelable(t.io);
            const snapshot = try capture(t.allocator, screen);
            mutex.unlock(t.io);
            const ns = start.durationTo(.now(t.io, .awake)).nanoseconds;
            bytes = snapshot.text.len;
            snapshot.deinit(t.allocator);
            if (i > 0) times[i - 1] = ns;
        }
        std.mem.sort(i128, &times, {}, std.sort.asc(i128));
        // Same lock and selection predicate used by Surface.hasSelection.
        const fast_start = std.Io.Timestamp.now(t.io, .awake);
        for (0..10_000) |_| {
            mutex.lockUncancelable(t.io);
            std.mem.doNotOptimizeAway(screen.selection);
            mutex.unlock(t.io);
        }
        const fast_ns = fast_start.durationTo(.now(t.io, .awake)).nanoseconds;
        std.debug.print("\nOPTIMIZATION_METRIC history lines={d} retained_rows={d} capture_bytes={d} capture_median_ns={d} min_ns={d} max_ns={d} empty_selection_predicate_ns_per_query={d}\n", .{ lines, screen.pages.total_rows, bytes, times[2], times[0], times[4], @divTrunc(fast_ns, 10_000) });
    }
}

test "accessibility indexed metadata matches full capture across selections and viewport moves" {
    const t = std.testing;
    const Selection = @import("Selection.zig");
    for ([_][]const u8{ "abc🙂e\xcc\x81z", "A\n\n\nB", "a中文z\nb🙂xy\nc123z", "1  \n2", "1234  7\n\nend", "a\n" ** 150 }) |input| {
        var screen = try Screen.init(t.io, t.allocator, .{ .cols = 4, .rows = 3, .max_scrollback_bytes = 1024 * 1024 });
        defer screen.deinit();
        try screen.testWriteString(input);
        var index: Index = .{};
        const initial = try captureIndexed(t.allocator, &screen, &index);
        defer initial.deinit(t.allocator);
        defer index.deinit(t.allocator);
        // Sparse storage grows with rows, not with the number of text units.
        try t.expect(index.spans.len <= screen.pages.total_rows * 3);
        for ([_]bool{ false, true }) |rectangle| {
            const last = screen.pages.total_rows - 1;
            for ([_]usize{ 0, last / 2, last }) |y| {
                for (0..4) |x| {
                    const a = screen.pages.pin(.{ .screen = .{ .x = @intCast(x), .y = @intCast(y) } }).?;
                    for (0..4) |end_x| {
                        const b = screen.pages.pin(.{ .screen = .{ .x = @intCast(end_x), .y = @intCast(last) } }).?;
                        try screen.select(Selection.init(b, a, rectangle));
                        for ([_]bool{ false, true }) |top| {
                            screen.pages.scroll(if (top) .top else .active);
                            const full = try capture(t.allocator, &screen);
                            defer full.deinit(t.allocator);
                            const ranges = try index.query(t.allocator, &screen);
                            defer t.allocator.free(ranges.selected);
                            try t.expectEqual(full.visible, ranges.visible);
                            try t.expectEqualSlices(Range, full.selected, ranges.selected);
                        }
                    }
                }
            }
        }
    }
}

test "accessibility tracker only replaces text for content changes and retries failed updates" {
    const t = std.testing;
    var term = try @import("Terminal.zig").init(t.io, t.allocator, .{ .cols = 10, .rows = 2, .max_scrollback_bytes = 1024 * 1024 });
    defer term.deinit(t.allocator);
    var tracker: Tracker = .{};
    defer tracker.deinit(t.allocator);
    try term.printString("old\nvisible\nlast");
    const first = (try tracker.read(t.allocator, &term, 0)).?;
    defer first.deinit(t.allocator);
    try t.expect(first.text != null);
    const pin = term.screens.active.pages.getTopLeft(.screen);
    try term.screens.active.select(@import("Selection.zig").init(pin, pin, false));
    var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, tracker.read(failing.allocator(), &term, first.revision));
    const selected = (try tracker.read(t.allocator, &term, first.revision)).?;
    defer selected.deinit(t.allocator);
    try t.expect(selected.text == null);
    try t.expectEqual(first.text_revision, selected.text_revision);
    term.screens.active.pages.scroll(.top);
    const scrolled = (try tracker.read(t.allocator, &term, selected.revision)).?;
    defer scrolled.deinit(t.allocator);
    try t.expect(scrolled.text == null);
    try t.expectEqual(first.text_revision, scrolled.text_revision);
    try t.expect((try tracker.read(t.allocator, &term, scrolled.revision)) == null);
    var revision = scrolled.revision;
    var stream = term.vtStream();
    defer stream.deinit();
    for ([_][]const u8{ "X", "\x1b[2K", "\x1b[?1049h", "ALT", "\x1b[?1049l", "\x1bc" }) |input| {
        stream.nextSlice(input);
        failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
        try t.expectError(error.OutOfMemory, tracker.read(failing.allocator(), &term, revision));
        const update = (try tracker.read(t.allocator, &term, revision)).?;
        defer update.deinit(t.allocator);
        try t.expect(update.text != null);
        try t.expect(update.text_revision > revision);
        const full = try capture(t.allocator, term.screens.active);
        defer full.deinit(t.allocator);
        try t.expectEqualStrings(full.text, update.text.?);
        revision = update.revision;
    }
    try term.resize(t.allocator, .{ .cols = 6, .rows = 3 });
    const resized = (try tracker.read(t.allocator, &term, revision)).?;
    defer resized.deinit(t.allocator);
    try t.expect(resized.text != null);
    try term.printString("a\nb\nc\nd\ne\nf\ng");
    const populated = (try tracker.read(t.allocator, &term, resized.revision)).?;
    defer populated.deinit(t.allocator);
    term.setScrollbackMaxLines(0);
    const pruned = (try tracker.read(t.allocator, &term, populated.revision)).?;
    defer pruned.deinit(t.allocator);
    try t.expect(pruned.text != null);
    const after_prune = try capture(t.allocator, term.screens.active);
    defer after_prune.deinit(t.allocator);
    try t.expectEqualStrings(after_prune.text, pruned.text.?);
    // An independent reader must receive text, even when an index already exists.
    const fresh = (try tracker.read(t.allocator, &term, 0)).?;
    defer fresh.deinit(t.allocator);
    try t.expect(fresh.text != null);
}

test "accessibility indexed capture frees partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var screen = try Screen.init(std.testing.io, std.testing.allocator, .{ .cols = 4, .rows = 3 });
            defer screen.deinit();
            try screen.testWriteString("a  b中🙂e\xcc\x81\n\nend");
            var index: Index = .{};
            const snapshot = try captureIndexed(alloc, &screen, &index);
            defer snapshot.deinit(alloc);
            defer index.deinit(alloc);
            const ranges = try index.query(alloc, &screen);
            defer alloc.free(ranges.selected);
        }
    }.run, .{});
}
