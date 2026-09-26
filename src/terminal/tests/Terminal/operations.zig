//! Terminal operations regression tests.
const support = @import("support.zig");
const std = support.std;
const testing = support.testing;
const size = support.size;
const pagepkg = support.pagepkg;
const style = support.style;
const Screen = support.Screen;
const Cell = support.Cell;
const init = support.init;
const isDirty = support.isDirty;
const clearDirty = support.clearDirty;

test "Terminal: setCursorPos saturates overflowing origin offsets" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    t.scrolling_region = .{
        .top = 2,
        .bottom = 7,
        .left = 3,
        .right = 8,
    };
    t.modes.set(.origin, true);

    t.setCursorPos(std.math.maxInt(usize), std.math.maxInt(usize));
    try testing.expectEqual(@as(size.CellCountInt, 8), t.screens.active.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 7), t.screens.active.cursor.y);
}

test "Terminal: input with no control characters" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 40, .rows = 40 });
    defer t.deinit(alloc);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("hello", str);
    }

    // The first row should be dirty
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 5, .y = 0 } }));
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 5, .y = 1 } }));
}

test "Terminal: input with basic wraparound" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 40 });
    defer t.deinit(alloc);

    // Basic grid writing
    for ("helloworldabc12") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("hello\nworld\nabc12", str);
    }
}

test "Terminal: input with basic wraparound dirty" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 40 });
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 4, .y = 0 } }));
    clearDirty(&t);
    try t.print('w');

    // Old row is dirty because cursor moved from there
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 4, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 1 } }));
}

test "Terminal: input unique style per cell" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 30, .rows = 30 });
    defer t.deinit(alloc);

    for (0..t.rows) |y| {
        for (0..t.cols) |x| {
            t.setCursorPos(y, x);
            try t.setAttribute(.{ .direct_color_bg = .{
                .r = @intCast(x),
                .g = @intCast(y),
                .b = 0,
            } });
            try t.print('x');
        }
    }
}

test "Terminal: input glitch text" {
    const glitch = @embedFile("../../res/glitch.txt");
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 30, .rows = 30 });
    defer t.deinit(alloc);

    // Get our initial grapheme capacity.
    const grapheme_cap = cap: {
        const page = t.screens.active.pages.pages.first.?;
        break :cap page.capacity().grapheme_bytes;
    };

    // Print glitch text until our capacity changes
    while (true) {
        const page = t.screens.active.pages.pages.first.?;
        if (page.capacity().grapheme_bytes != grapheme_cap) break;
        try t.printString(glitch);
    }

    // We're testing to make sure that grapheme capacity gets increased.
    const page = t.screens.active.pages.pages.first.?;
    try testing.expect(page.capacity().grapheme_bytes > grapheme_cap);
}

test "Terminal: zero-width character at start" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // This used to crash the terminal. This is not allowed so we should
    // just ignore it.
    try t.print(0x200D);

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);

    // Should not be dirty since we changed nothing.
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

// https://github.com/ghostty-org/ghostty/pull/12581
test "Terminal: zero-width character attaches to pending wrap cell" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 2, .rows = 2 });
    defer t.deinit(testing.allocator);

    // Disable grapheme clustering to exercise the fallback path.
    t.modes.set(.grapheme_cluster, false);

    try t.print('x');
    try t.print('å');
    try t.print(0x0332); // Combining low line.

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("xå̲", str);
}

test "Terminal: caps zero-width codepoints attached to one cell" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 2, .rows = 2 });
    defer t.deinit(testing.allocator);

    t.modes.set(.grapheme_cluster, false);
    try t.print('A');

    const initial_capacity = t.screens.active.cursor.page_pin.node.capacity().grapheme_bytes;
    for (0..pagepkg.grapheme_max_len * 4) |_| try t.print(0x0301);

    const list_cell = t.screens.active.pages.getCell(.{
        .screen = .{ .x = 0, .y = 0 },
    }).?;
    try testing.expectEqual(
        @as(usize, pagepkg.grapheme_max_len),
        list_cell.node.page().lookupGrapheme(list_cell.cell).?.len,
    );
    try testing.expectEqual(
        initial_capacity,
        list_cell.node.capacity().grapheme_bytes,
    );
}

test "Terminal: Fitzpatrick skin tone next valid base" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // This is: "👋🏿" (waving hand with dark skin tone)
    try t.print(0x1F44B); // 👋 Waving hand (valid base)
    try t.print(0x1F3FF); // 🏿 Dark skin tone modifier

    // The skin tone should combine with the base emoji into a single grapheme cluster,
    // taking 2 cells (wide character).
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Row should be dirty
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    // The base emoji should be in cell 0 with the skin tone as a grapheme
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F44B), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
}

test "Terminal: Fitzpatrick skin tone next to non-base" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // This is: "🏿" (which may not render correctly in your editor!)
    try t.print(0x22); // "
    try t.print(0x1F3FF); // Dark skin tone
    try t.print(0x22); // "

    // We should have 4 cells taken up. Importantly, the skin tone
    // should not join with the quotes.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);

    // Row should be dirty
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x22), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F3FF), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x22), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: soft wrap" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 3, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hel\nlo", str);
    }
}

test "Terminal: disabled wraparound with wide char and one space" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    t.modes.set(.wraparound, false);

    // This puts our cursor at the end and there is NO SPACE for a
    // wide character.
    try t.printString("AAAA");
    clearDirty(&t);
    try t.print(0x1F6A8); // Police car light
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAA", str);
    }

    // Make sure we printed nothing
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    // Should not be dirty since we didn't modify anything
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: disabled wraparound with wide char and no space" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    t.modes.set(.wraparound, false);

    // This puts our cursor at the end and there is NO SPACE for a
    // wide character.
    try t.printString("AAAAA");
    clearDirty(&t);
    try t.print(0x1F6A8); // Police car light
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAAA", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    // Should not be dirty since we didn't modify anything
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: carriage return unsets pending wrap" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap == true);
    t.carriageReturn();
    try testing.expect(t.screens.active.cursor.pending_wrap == false);
}

test "Terminal: backspace" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // BS
    for ("hello") |c| try t.print(c);
    t.backspace();
    try t.print('y');
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("helly", str);
    }
}

test "Terminal: horizontal tabs" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    // HT
    try t.print('1');
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 8), t.screens.active.cursor.x);

    // HT
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 16), t.screens.active.cursor.x);

    // HT at the end
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 19), t.screens.active.cursor.x);
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 19), t.screens.active.cursor.x);
}

test "Terminal: horizontal tabs starting on tabstop" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(t.screens.active.cursor.y, 9);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y, 9);
    t.horizontalTab();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("        X       A", str);
    }
}

test "Terminal: horizontal tabs back" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    // Edge of screen
    t.setCursorPos(t.screens.active.cursor.y, 20);

    // HT
    t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 16), t.screens.active.cursor.x);

    // HT
    t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 8), t.screens.active.cursor.x);

    // HT
    t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
}

test "Terminal: horizontal tabs back starting on tabstop" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(t.screens.active.cursor.y, 9);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y, 9);
    t.horizontalTabBack();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A       X", str);
    }
}

test "Terminal: cursorPos relative to origin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.scrolling_region.top = 2;
    t.scrolling_region.bottom = 3;
    t.modes.set(.origin, true);
    t.setCursorPos(1, 1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nX", str);
    }
}

test "Terminal: cursorPos relative to origin with left/right" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.scrolling_region.top = 2;
    t.scrolling_region.bottom = 3;
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.modes.set(.origin, true);
    t.setCursorPos(1, 1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n  X", str);
    }
}

// Probably outdated, but dates back to the original terminal implementation.
test "Terminal: setCursorPos (original test)" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);

    // Setting it to 0 should keep it zero (1 based)
    t.setCursorPos(0, 0);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);

    // Should clamp to size
    t.setCursorPos(81, 81);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.y);

    // Should reset pending wrap
    t.setCursorPos(0, 80);
    try t.print('c');
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.setCursorPos(0, 80);
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    // Origin mode
    t.modes.set(.origin, true);

    // No change without a scroll region
    t.setCursorPos(81, 81);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.y);

    // Set the scroll region
    t.setTopAndBottomMargin(10, t.rows);
    t.setCursorPos(0, 0);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.y);

    t.setCursorPos(1, 1);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.y);

    t.setCursorPos(100, 0);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.y);

    t.setTopAndBottomMargin(10, 11);
    t.setCursorPos(2, 0);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 10), t.screens.active.cursor.y);
}

test "Terminal: cursorUp basic" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(3, 1);
    try t.print('A');
    t.cursorUp(10);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" X\n\nA", str);
    }
}

test "Terminal: cursorLeft no wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.cursorLeft(10);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nB", str);
    }
}

test "Terminal: cursorLeft unsets pending wrap state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCXE", str);
    }
}

test "Terminal: cursorLeft unsets pending wrap state with longer jump" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorLeft(3);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AXCDE", str);
    }
}

test "Terminal: cursorLeft reverse wrap with pending wrap state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: cursorLeft reverse wrap extended with pending wrap state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: cursorLeft reverse wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);

    for ("ABCDE1") |c| try t.print(c);
    t.cursorLeft(2);
    try t.print('X');
    try testing.expect(t.screens.active.cursor.pending_wrap);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX\n1", str);
    }
}

test "Terminal: cursorLeft reverse wrap with no soft wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);

    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(2);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\nX", str);
    }
}

test "Terminal: cursorLeft extended reverse wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);

    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(2);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX\n1", str);
    }
}

test "Terminal: cursorLeft extended reverse wrap bottom wraparound" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);

    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(1 + t.cols + 1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\n1\n    X", str);
    }
}

test "Terminal: cursorLeft extended reverse wrap is priority if both set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);
    t.modes.set(.reverse_wrap_extended, true);

    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(1 + t.cols + 1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\n1\n    X", str);
    }
}

test "Terminal: cursorLeft reverse wrap on first row" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);

    t.setTopAndBottomMargin(3, 0);
    t.setCursorPos(1, 2);
    t.cursorLeft(1000);

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
}

test "Terminal: cursorDown basic" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.cursorDown(10);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\n\n X", str);
    }
}

test "Terminal: default style is empty" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint.data);
        try testing.expectEqual(@as(style.Id, 0), cell.style_id);
    }
}

test "Terminal: bold style" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .bold = {} });
    try t.print('A');

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint.data);
        try testing.expect(cell.style_id != 0);
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 1);
    }
}

test "Terminal: garbage collect overwritten" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .bold = {} });
    try t.print('A');
    t.setCursorPos(1, 1);
    try t.setAttribute(.{ .unset = {} });
    try t.print('B');

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'B'), cell.content.codepoint.data);
        try testing.expect(cell.style_id == 0);
    }

    // verify we have no styles in our style map
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}

test "Terminal: do not garbage collect old styles in use" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .bold = {} });
    try t.print('A');
    try t.setAttribute(.{ .unset = {} });
    try t.print('B');

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'B'), cell.content.codepoint.data);
        try testing.expect(cell.style_id == 0);
    }

    // verify we have no styles in our style map
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.styles.count());
}

test "Terminal: DECALN" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 2 });
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    try t.decaln();

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);

    for (0..t.rows) |y| try testing.expect(isDirty(&t, .{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("EE\nEE", str);
    }
}

test "Terminal: decaln preserves color" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    try t.setAttribute(.{ .direct_color_bg = .{ .r = 0xFF, .g = 0, .b = 0 } });
    t.modes.set(.origin, true);
    t.setTopAndBottomMargin(2, 3);
    try t.decaln();
    t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nEEE\nEEE", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: saveCursor" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .bold = {} });
    t.screens.active.charset.gr = .G3;
    t.modes.set(.origin, true);
    t.saveCursor();
    t.screens.active.charset.gr = .G0;
    try t.setAttribute(.{ .unset = {} });
    t.modes.set(.origin, false);
    t.restoreCursor();
    try testing.expect(t.screens.active.cursor.style.flags.bold);
    try testing.expect(t.screens.active.charset.gr == .G3);
    try testing.expect(t.modes.get(.origin));
}

test "Terminal: saveCursor position" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(1, 5);
    try t.print('A');
    t.saveCursor();
    t.setCursorPos(1, 1);
    try t.print('B');
    t.restoreCursor();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B   AX", str);
    }
}

test "Terminal: saveCursor pending wrap state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(1, 5);
    try t.print('A');
    t.saveCursor();
    t.setCursorPos(1, 1);
    try t.print('B');
    t.restoreCursor();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B   A\nX", str);
    }
}

test "Terminal: saveCursor protected pen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    try testing.expect(t.screens.active.cursor.protected);
    t.setCursorPos(1, 10);
    t.saveCursor();
    t.setProtectedMode(.off);
    try testing.expect(!t.screens.active.cursor.protected);
    t.restoreCursor();
    try testing.expect(t.screens.active.cursor.protected);
}

test "Terminal: restoreCursor uses default style on OutOfSpace" {
    // Tests that restoreCursor falls back to default style when
    // manualStyleUpdate fails with OutOfSpace (can't split a 1-row page
    // and styles are at max capacity).
    const alloc = testing.allocator;
    const io_impl = testing.io;

    // Use a single row so the page can't be split
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    // Set a style and save the cursor
    try t.setAttribute(.{ .bold = {} });
    t.saveCursor();

    // Clear the style
    try t.setAttribute(.{ .unset = {} });
    try testing.expect(!t.screens.active.cursor.style.flags.bold);

    // Fill the style map to max capacity
    const max_styles = std.math.maxInt(size.CellCountInt);
    while (t.screens.active.cursor.page_pin.node.capacity().styles < max_styles) {
        _ = t.screens.active.increaseCapacity(
            t.screens.active.cursor.page_pin.node,
            .styles,
        ) catch break;
    }

    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(max_styles, page.capacity.styles);

    // Fill all style slots using the StyleSet's layout capacity which accounts
    // for the load factor. The capacity in the layout is the actual max number
    // of items that can be stored.
    {
        page.pauseIntegrityChecks(true);
        defer page.pauseIntegrityChecks(false);
        defer page.assertIntegrity();

        const max_items = page.styles.layout.cap;
        var n: usize = 1;
        while (n < max_items) : (n += 1) {
            _ = page.styles.add(
                page.memory,
                .{ .bg_color = .{ .rgb = @bitCast(@as(u24, @intCast(n))) } },
            ) catch break;
        }
    }

    // Restore cursor - should fall back to default style since page
    // can't be split (1 row) and styles are at max capacity
    t.restoreCursor();

    // The style should be reset to default because OutOfSpace occurred
    try testing.expect(!t.screens.active.cursor.style.flags.bold);
    try testing.expectEqual(style.default_id, t.screens.active.cursor.style_id);
}

test "Terminal: OSC133A click_events=1 sets click to click_events" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Verify default state is none
    try testing.expectEqual(.none, t.screens.active.semantic_prompt.click);

    // OSC 133;A with click_events=1
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=1",
    });

    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .click_events = .absolute }, t.screens.active.semantic_prompt.click);
}

test "Terminal: OSC133A click_events=2 sets click to click_events (relative)" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Verify default state is none
    try testing.expectEqual(.none, t.screens.active.semantic_prompt.click);

    // OSC 133;A with click_events=2
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=2",
    });

    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .click_events = .relative }, t.screens.active.semantic_prompt.click);
}

test "Terminal: OSC133A click_events=0 does not set click_events" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // OSC 133;A with click_events=0
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=0",
    });

    // Should remain none since click_events=0 doesn't activate anything
    try testing.expectEqual(.none, t.screens.active.semantic_prompt.click);
}

test "Terminal: OSC133A cl option sets click to cl value" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // OSC 133;A with cl=m (multiple)
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "cl=m",
    });

    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .cl = .multiple }, t.screens.active.semantic_prompt.click);
}

test "Terminal: OSC133A cl=line sets click to line" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "cl=line",
    });

    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .cl = .line }, t.screens.active.semantic_prompt.click);
}

test "Terminal: OSC133A click_events=1 takes priority over cl" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // OSC 133;A with both click_events=1 and cl=m
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=1;cl=m",
    });

    // click_events should take priority
    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .click_events = .absolute }, t.screens.active.semantic_prompt.click);
}

test "Terminal: OSC133A click_events=0 falls back to cl" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // OSC 133;A with click_events=0 and cl=v
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=0;cl=v",
    });

    // Should fall back to cl since click_events is disabled
    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .cl = .conservative_vertical }, t.screens.active.semantic_prompt.click);
}

test "Terminal: OSC133A no click options leaves click as none" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // OSC 133;A with no click-related options
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "aid=123",
    });

    try testing.expectEqual(.none, t.screens.active.semantic_prompt.click);
}

test "Terminal: cursorIsAtPrompt" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    try testing.expect(!t.cursorIsAtPrompt());
    try t.semanticPrompt(.init(.prompt_start));
    try testing.expect(t.cursorIsAtPrompt());
    for ("$ ") |c| try t.print(c);

    // Input is also a prompt
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expect(t.cursorIsAtPrompt());
    for ("ls") |c| try t.print(c);

    // But once we say we're starting output, we're not a prompt
    // (cursor is not at x=0, so the Fish heuristic doesn't trigger)
    try t.semanticPrompt(.init(.end_input_start_output));
    // Still a prompt because this line has a prompt
    try testing.expect(t.cursorIsAtPrompt());
    try t.linefeed();
    try testing.expect(!t.cursorIsAtPrompt());

    // Until we know we're at a prompt again
    try t.linefeed();
    try t.semanticPrompt(.init(.prompt_start));
    try testing.expect(t.cursorIsAtPrompt());
}

test "Terminal: cursor defaults update current default cursor" {
    var t = try init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 10,
        .default_cursor_style = .bar,
        .default_cursor_blink = true,
    });
    defer t.deinit(testing.allocator);

    // Initialization applies the configured defaults.
    try testing.expect(t.cursor.is_default);
    try testing.expectEqual(.bar, t.screens.active.cursor.cursor_style);
    try testing.expect(t.modes.get(.cursor_blinking));

    // Configuration changes are immediately visible while the cursor still
    // follows its defaults.
    t.setDefaultCursorStyle(.underline);
    t.setDefaultCursorBlink(false);
    try testing.expect(t.cursor.is_default);
    try testing.expectEqual(.underline, t.screens.active.cursor.cursor_style);
    try testing.expect(!t.modes.get(.cursor_blinking));

    // Null restores the terminal emulator's blinking default.
    t.setDefaultCursorBlink(null);
    try testing.expect(t.modes.get(.cursor_blinking));
}

test "Terminal: cursor defaults do not override explicit cursor" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    t.setCursorStyle(.blinking_bar);
    try testing.expect(!t.cursor.is_default);
    try testing.expectEqual(.bar, t.screens.active.cursor.cursor_style);
    try testing.expect(t.modes.get(.cursor_blinking));

    // New defaults are retained without replacing the explicit appearance.
    t.setDefaultCursorStyle(.underline);
    t.setDefaultCursorBlink(false);
    try testing.expectEqual(.underline, t.cursor.default_style);
    try testing.expectEqual(false, t.cursor.default_blink);
    try testing.expectEqual(.bar, t.screens.active.cursor.cursor_style);
    try testing.expect(t.modes.get(.cursor_blinking));

    // Selecting the default applies the values that changed above.
    t.setCursorStyle(.default);
    try testing.expect(t.cursor.is_default);
    try testing.expectEqual(.underline, t.screens.active.cursor.cursor_style);
    try testing.expect(!t.modes.get(.cursor_blinking));

    // A full reset also leaves the cursor on the configured defaults.
    t.setCursorStyle(.steady_block);
    t.fullReset();
    try testing.expect(t.cursor.is_default);
    try testing.expectEqual(.underline, t.screens.active.cursor.cursor_style);
    try testing.expect(!t.modes.get(.cursor_blinking));
}

test "Terminal: DECCOLM unset" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");
    try testing.expectEqual(@as(usize, 80), t.cols);
    try testing.expectEqual(@as(usize, 5), t.rows);
}

test "Terminal: DECCOLM preserves SGR bg" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: cursorLeft reverse wrap with pending wrap above top margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    for (0..3) |action| {
        var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
        defer t.deinit(alloc);

        t.modes.set(.wraparound, true);
        t.modes.set(.reverse_wrap, true);
        t.modes.set(.enable_left_and_right_margin, true);
        t.setLeftAndRightMargin(1, 2);
        for ("AB") |c| try t.print(c);
        t.saveCursor();

        // Restore pending wrap at the left margin, above the top margin.
        t.setLeftAndRightMargin(2, 5);
        t.setTopAndBottomMargin(3, 5);
        t.restoreCursor();
        try testing.expect(t.screens.active.cursor.pending_wrap);

        switch (action) {
            0 => t.cursorLeft(1),
            1 => t.cursorLeft(0), // CUB zero means one.
            2 => t.backspace(),
            else => unreachable,
        }
        try testing.expect(!t.screens.active.cursor.pending_wrap);
        try testing.expectEqual(1, t.screens.active.cursor.x);
        try testing.expectEqual(0, t.screens.active.cursor.y);
        try t.print('X');

        {
            const str = try t.plainString(alloc);
            defer alloc.free(str);
            try testing.expectEqualStrings("AX", str);
        }
    }
}
