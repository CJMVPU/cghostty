//! Terminal printing regression tests.
const support = @import("support.zig");
const Terminal = support.Terminal;
const std = support.std;
const testing = support.testing;
const charsets = support.charsets;
const hyperlink = support.hyperlink;
const kitty = support.kitty;
const sgr = support.sgr;
const pagepkg = support.pagepkg;
const Cell = support.Cell;
const init = support.init;
const printSliceFast = support.printSliceFast;
const isDirty = support.isDirty;
const clearDirty = support.clearDirty;
const expectGraphemeWidthParity = support.expectGraphemeWidthParity;
const testPrintSliceDifferential = support.testPrintSliceDifferential;

// https://github.com/mitchellh/ghostty/issues/1400
test "Terminal: print single very long line" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // This would crash for issue 1400. So the assertion here is
    // that we simply do not crash.
    for (0..1000) |_| try t.print('x');
}

test "Terminal: print wide char" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.print(0x1F600); // Smiley face
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F600), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print wide char at edge creates spacer head" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    t.setCursorPos(1, 10);
    try t.print(0x1F600); // Smiley face
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 9, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F600), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    // Our first row just had a spacer head added which does not affect
    // rendering so only the place where the wide char was printed
    // should be marked.
    // BUT old row is dirty because cursor moved from there
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 1 } }));
}

test "Terminal: print wide char with 1-column width" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 1, .rows = 2 });
    defer t.deinit(alloc);

    try t.print('😀'); // 0x1F600

    // This prints a space so we should be dirty.
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print wide char in single-width terminal" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 1, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.print(0x1F600); // Smiley face
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print over wide char at 0,0" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.print(0x1F600); // Smiley face
    t.setCursorPos(0, 0);
    try t.print('A');

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 1 } }));
}

test "Terminal: print over wide char at col 0 corrupts previous row" {
    // Crash found by AFL++ fuzzer (afl-out/stream/default/crashes/id:000002).
    //
    // printCell, when overwriting a wide cell with a narrow cell at x<=1
    // and y>0, sets the last cell of the previous row to .narrow — even
    // when that cell is a .spacer_tail rather than a .spacer_head. This
    // orphans the .wide cell at cols-2.
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    // Fill rows 0 and 1 with wide chars (5 per row on a 10-col terminal).
    for (0..10) |_| try t.print(0x4E2D);

    // Move cursor to row 1, col 0 (on top of a wide char) and print a
    // narrow character. This triggers printCell's .wide branch which
    // corrupts row 0's last cell: col 9 changes from .spacer_tail to
    // .narrow, orphaning the .wide at col 8.
    t.setCursorPos(2, 1);
    try t.print('A');

    // Row 1, col 0 should be narrow (we just overwrote the wide char).
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        try testing.expectEqual(Cell.Wide.narrow, list_cell.cell.wide);
    }
    // Row 0, col 8 should still be .wide (the last wide char on the row).
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 8, .y = 0 } }).?;
        try testing.expectEqual(Cell.Wide.wide, list_cell.cell.wide);
    }
    // Row 0, col 9 must remain .spacer_tail to pair with the .wide at col 8.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 9, .y = 0 } }).?;
        try testing.expectEqual(Cell.Wide.spacer_tail, list_cell.cell.wide);
    }
}

test "Terminal: print over wide spacer tail" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    try t.print('橋');
    t.setCursorPos(1, 2);
    try t.print('X');

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'X'), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" X", str);
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print over wide char with bold" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.setAttribute(.{ .bold = {} });
    try t.print(0x1F600); // Smiley face
    // verify we have styles in our style map
    {
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 1), page.styles.count());
    }

    // Go back and overwrite with no style
    t.setCursorPos(0, 0);
    try t.setAttribute(.{ .unset = {} });
    try t.print('A'); // Smiley face

    // verify our style is gone
    {
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 0), page.styles.count());
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print over wide char with bg color" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.print(0x1F600); // Smiley face
    // verify we have styles in our style map
    {
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 1), page.styles.count());
    }

    // Go back and overwrite with no style
    t.setCursorPos(0, 0);
    try t.setAttribute(.{ .unset = {} });
    try t.print('A'); // Smiley face

    // verify our style is gone
    {
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 0), page.styles.count());
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print multicodepoint grapheme, disabled mode 2027" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // https://github.com/mitchellh/ghostty/issues/289
    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    // We should have 6 cells taken up
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 6), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F468), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(list_cell.node.page().lookupGrapheme(cell) == null);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F469), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(list_cell.node.page().lookupGrapheme(cell) == null);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F467), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expect(list_cell.node.page().lookupGrapheme(cell) == null);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 5, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(list_cell.node.page().lookupGrapheme(cell) == null);
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: enabling grapheme mode handles stored breaks" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 1 });
    defer t.deinit(testing.allocator);

    t.modes.set(.grapheme_cluster, false);
    try t.print('a');
    try t.print(0x200B); // Zero width space is stored on the prior cell.

    t.modes.set(.grapheme_cluster, true);
    try t.print(0x0301);

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("a\xE2\x80\x8B\xCC\x81", str);
}

test "Terminal: graphemeWidth parity" {
    try expectGraphemeWidthParity(&.{ 0x2764, 0xFE0F });
    try expectGraphemeWidthParity(&.{ 'x', 0xFE0F, 0xFE0F });
    try expectGraphemeWidthParity(&.{ 0x231A, 0xFE0E, 0xFE0F });
    try expectGraphemeWidthParity(&.{ 0x1F3F4, 0x200D, 0x2620, 0xFE0F });
    try expectGraphemeWidthParity(&.{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467 });
    try expectGraphemeWidthParity(&.{ 0x23, 0xFE0F, 0x20E3 });
    try expectGraphemeWidthParity(&.{ '1', 0x20E3 });
    try expectGraphemeWidthParity(&.{ 0x1F44B, 0x1F3FF });
    try expectGraphemeWidthParity(&.{ 0x1F1E6, 0x1F1E7, 0x1F1E8 });
    try expectGraphemeWidthParity(&.{ 'a', 'b' });
    try expectGraphemeWidthParity(&.{ 0x0301, 0x0302 });
}

test "Terminal: VS16 doesn't make character with 2027 disabled" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Disable grapheme clustering
    t.modes.set(.grapheme_cluster, false);

    try t.print(0x2764); // Heart
    try t.print(0xFE0F); // VS16 to make wide

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("❤️", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: ignored VS16 doesn't mark dirty" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Disable grapheme clustering
    t.modes.set(.grapheme_cluster, false);

    try t.print(0x2764); // Heart
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    clearDirty(&t);
    try t.print(0xFE0F); // VS16 to make wide
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print invalid VS16 non-grapheme" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // https://github.com/mitchellh/ghostty/issues/1482
    try t.print('x');
    try t.print(0xFE0F);

    // We should have 1 narrow cell.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'x'), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
    }
}

test "Terminal: invalid VS16 doesn't mark dirty" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Disable grapheme clustering
    t.modes.set(.grapheme_cluster, false);

    try t.print('x');
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    clearDirty(&t);
    try t.print(0xFE0F); // VS16 to make wide
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

// https://github.com/ghostty-org/ghostty/pull/12596
test "Terminal: variation selectors apply to preceding codepoint" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // Pirate flag: black flag + ZWJ + skull and crossbones + VS16.
    try t.print(0x1F3F4);
    try t.print(0x200D);
    try t.print(0x2620);
    try t.print(0xFE0F);

    const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    const cell = list_cell.cell;
    try testing.expectEqual(@as(u21, 0x1F3F4), cell.content.codepoint.data);
    try testing.expect(cell.hasGrapheme());
    try testing.expectEqualSlices(u21, &.{ 0x200D, 0x2620, 0xFE0F }, list_cell.node.page().lookupGrapheme(cell).?);
}

test "Terminal: print multicodepoint grapheme, mode 2027" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/289
    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Row should be dirty
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F468), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 4), cps.len);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: keypad sequence VS15" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // This is: "#︎" (number sign with text presentation selector)
    try t.print(0x23); // # Number sign (valid base)
    try t.print(0xFE0E); // VS15 (text presentation selector)

    // VS15 should combine with the base character into a single grapheme cluster,
    // taking 1 cell (narrow character).
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    // Row should be dirty
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    // The base emoji should be in cell 0 with the skin tone as a grapheme
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x23), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: keypad sequence VS16" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // This is: "#️" (number sign with emoji presentation selector)
    try t.print(0x23); // # Number sign (valid base)
    try t.print(0xFE0F); // VS16 (emoji presentation selector)

    // VS16 should combine with the base character into a single grapheme cluster,
    // taking 2 cells (wide character).
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Row should be dirty
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    // The base emoji should be in cell 0 with the skin tone as a grapheme
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x23), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
}

test "Terminal: multicodepoint grapheme marks dirty on every codepoint" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/289
    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    clearDirty(&t);
    try t.print(0x200D);
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    clearDirty(&t);
    try t.print(0x1F469);
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    clearDirty(&t);
    try t.print(0x200D);
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    clearDirty(&t);
    try t.print(0x1F467);
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
}

test "Terminal: VS15 to make narrow character" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x2614); // Umbrella with rain drops, width=2
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    clearDirty(&t);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    try t.print(0xFE0E); // VS15 to make narrow
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    clearDirty(&t);

    // VS15 should send us back a cell since our char is no longer wide.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("☔︎", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2614), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: VS15 on already narrow emoji" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x26C8); // Thunder cloud and rain, width=1
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    clearDirty(&t);
    try t.print(0xFE0E); // VS15 to make narrow
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    clearDirty(&t);

    // Character takes up one cell
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("⛈︎", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x26C8), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: print invalid VS15 following emoji is wide" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print('\u{1F9E0}'); // 🧠
    try t.print(0xFE0E); // not valid with U+1F9E0 as base

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '\u{1F9E0}'), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: print invalid VS15 in emoji ZWJ sequence" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print('\u{1F469}'); // 👩
    try t.print(0xFE0E); // not valid with U+1F469 as base
    try t.print('\u{200D}'); // ZWJ
    try t.print('\u{1F466}'); // 👦

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '\u{1F469}'), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ '\u{200D}', '\u{1F466}' }, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: VS15 to make narrow character with pending wrap" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 4 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try testing.expect(t.modes.get(.wraparound));

    try t.print(0x1F34B); // Lemon, width=2
    try t.print(0x2614); // Umbrella with rain drops, width=2
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    clearDirty(&t);

    // We only move to the end of the line because we're in a pending wrap
    // state.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 3), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    try t.print(0xFE0E); // VS15 to make narrow
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    clearDirty(&t);

    // VS15 should clear the pending wrap state
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 3), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("🍋☔︎", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2614), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }

    // VS15 should not affect the previous grapheme
    {
        const lemon_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?.cell;
        try testing.expectEqual(@as(u21, 0x1F34B), lemon_cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, lemon_cell.wide);
        const spacer_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?.cell;
        try testing.expectEqual(@as(u21, 0), spacer_cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.spacer_tail, spacer_cell.wide);
    }
}

test "Terminal: VS15 narrows wide cell under cursor with wraparound disabled" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    t.modes.set(.grapheme_cluster, true);
    t.modes.set(.wraparound, false);

    // First create a wide cell spanning columns 4 and 5.
    t.setCursorPos(1, 4);
    try t.print(0x2614);

    // Make column 4 the right margin and put the cursor on the wide base.
    // With wraparound disabled, grapheme lookup selects the cell under the
    // cursor when it has content.
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(1, 4);
    t.setCursorPos(1, 4);
    try t.print(0xFE0E);

    try testing.expectEqual(@as(usize, 3), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    const base = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?.cell;
    try testing.expectEqual(Cell.Wide.narrow, base.wide);
    try testing.expect(base.hasGrapheme());
    const tail = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?.cell;
    try testing.expectEqual(Cell.Wide.narrow, tail.wide);
}

test "Terminal: VS15 narrows wide cell under restored pending cursor" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    t.modes.set(.grapheme_cluster, true);
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(1, 4);

    // Save a pending-wrap cursor at column 4.
    t.setCursorPos(1, 4);
    try t.print('X');
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.saveCursor();

    // Widen the margin and replace that cell with a wide character.
    t.setLeftAndRightMargin(1, 5);
    t.setCursorPos(1, 4);
    try t.print(0x2614);

    // Restoring also restores pending_wrap, so grapheme lookup selects the
    // wide base under the cursor rather than its spacer tail.
    t.restoreCursor();
    try testing.expect(t.screens.active.cursor.pending_wrap);
    try t.print(0xFE0E);

    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    const base = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?.cell;
    try testing.expectEqual(Cell.Wide.narrow, base.wide);
    try testing.expect(base.hasGrapheme());
    const tail = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?.cell;
    try testing.expectEqual(Cell.Wide.narrow, tail.wide);
}

test "Terminal: VS16 to make wide character on next line" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 3 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    t.cursorRight(2);
    try t.print('#');
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 2, .y = 0 } }));
    clearDirty(&t);

    try t.print(0xFE0F); // VS16 to make wide

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 2, .y = 0 } }));
    clearDirty(&t);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    {
        // Previous cell turns into spacer_head
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        // '#' cell is wide
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '#'), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0xFE0F}, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        // spacer_tail
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: VS16 to make wide character on next line with hyperlink" {
    // Regression test for the crash fixed in print's grapheme `.wide` path:
    // writing a spacer_head at the screen edge before row.wrap was set.
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 3 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering and activate a hyperlink so printCell
    // calls cursorSetHyperlink (which runs page integrity checks).
    t.modes.set(.grapheme_cluster, true);
    try t.screens.active.startHyperlink("http://example.com", null);

    t.cursorRight(2);
    try t.print('#');
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    // Without the fix, this panicked with UnwrappedSpacerHead.
    try t.print(0xFE0F); // VS16 to make wide

    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    {
        // Previous cell turns into spacer_head and remains hyperlinked.
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
        try testing.expect(cell.hyperlink);
        try testing.expect(list_cell.row.wrap);
    }
    {
        // '#' cell is now wide and still hyperlinked.
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '#'), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0xFE0F}, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expect(cell.hyperlink);
    }
    {
        // spacer_tail inherits hyperlink as part of the same grapheme cell.
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(cell.hyperlink);
    }
}

test "Terminal: VS16 widening when the spacer tail grows the page" {
    // Regression test for a stale cell pointer in print's grapheme `.wide`
    // path: writing the spacer tail can grow the page to fit the hyperlink,
    // which replaces the page and invalidates the pointer to the wide cell.
    var t = try init(testing.io, testing.allocator, .{ .rows = 10, .cols = 20 });
    defer t.deinit(testing.allocator);

    t.modes.set(.grapheme_cluster, true);
    try t.screens.active.startHyperlink("http://example.com", null);

    // Fill the page hyperlink map until a single slot is left. The '#' below
    // takes that slot so the spacer tail is what forces the page to grow.
    while (true) {
        const page = t.screens.active.cursor.page_pin.node.page();
        const map = page.hyperlink_map.map(page.memory);
        if (map.maxLoad() - map.count() == 1) break;
        try t.print('x');
    }

    const x = t.screens.active.cursor.x;
    const y = t.screens.active.cursor.y;
    try t.print('#');

    // Without the fix this crashed appending to a freed page.
    try t.print(0xFE0F);

    {
        // '#' is wide and carries the VS16 grapheme.
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = x,
            .y = y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '#'), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(
            u21,
            &.{0xFE0F},
            list_cell.node.page().lookupGrapheme(cell).?,
        );
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = x + 1,
            .y = y,
        } }).?;
        try testing.expectEqual(Cell.Wide.spacer_tail, list_cell.cell.wide);
    }
}

test "Terminal: grapheme transfer when widening wraps to the next line" {
    // Covers print's grapheme `.wide` path where the previous cell already
    // holds grapheme data and has to be moved to the wrapped row.
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 3 });
    defer t.deinit(testing.allocator);

    t.modes.set(.grapheme_cluster, true);
    t.cursorRight(2);

    // A narrow emoji, then ZWJ, then a second emoji. The ZWJ attaches
    // without changing the width, so the cell has grapheme data by the time
    // the second emoji widens it.
    try t.print(0x263A);
    try t.print(0x200D);
    try t.print(0x2764);

    {
        // The old cell becomes a spacer head on the wrapped row.
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = 2,
            .y = 0,
        } }).?;
        try testing.expectEqual(Cell.Wide.spacer_head, list_cell.cell.wide);
        try testing.expect(list_cell.row.wrap);
    }
    {
        // The grapheme moved with the base codepoint.
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = 0,
            .y = 1,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x263A), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqualSlices(
            u21,
            &.{ 0x200D, 0x2764 },
            list_cell.node.page().lookupGrapheme(cell).?,
        );
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = 1,
            .y = 1,
        } }).?;
        try testing.expectEqual(Cell.Wide.spacer_tail, list_cell.cell.wide);
    }
}

test "Terminal: VS16 to make wide character with pending wrap" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 3 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    t.cursorRight(1);
    try t.print('#');
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    try t.print(0xFE0F); // VS16 to make wide

    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    {
        // '#' cell is wide
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '#'), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0xFE0F}, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        // spacer_tail
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: VS16 to make wide character with mode 2027" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x2764); // Heart
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    clearDirty(&t);
    try t.print(0xFE0F); // VS16 to make wide
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    clearDirty(&t);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("❤️", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: VS16 repeated with mode 2027" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x2764); // Heart
    try t.print(0xFE0F); // VS16 to make wide
    try t.print(0x2764); // Heart
    try t.print(0xFE0F); // VS16 to make wide

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("❤️❤️", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: print invalid VS16 grapheme" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/1482
    try t.print('x');
    try t.print(0xFE0F); // invalid VS16

    // We should have 1 cells taken up, and narrow.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'x'), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: print invalid VS16 with second char" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/1482
    try t.print('x');
    try t.print(0xFE0F);
    try t.print('y');

    // We should have 2 cells taken up, from two separate narrow characters.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'x'), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'y'), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: print grapheme ò (o with nonspacing mark) should be narrow" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print('o');
    try t.print(0x0300); // combining grave accent

    // We should have 1 cell taken up.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'o'), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0x0300}, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: print Devanagari grapheme should be wide" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // क्‍ष
    try t.print(0x0915);
    try t.print(0x094D);
    try t.print(0x200D);
    try t.print(0x0937);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x0915), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ 0x094D, 0x200D, 0x0937 }, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: print Devanagari grapheme should be wide on next line" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 3 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    t.cursorRight(2);

    // क्‍ष
    try t.print(0x0915);
    try t.print(0x094D);
    try t.print(0x200D);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    // This one increases the width to wide
    try t.print(0x0937);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    {
        // Previous cell turns into spacer_head
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        // Devanagari grapheme is wide
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x0915), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ 0x094D, 0x200D, 0x0937 }, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: print Devanagari grapheme should be wide on next page" {
    const rows = pagepkg.std_capacity.rows;
    const cols = pagepkg.std_capacity.cols;
    var t = try init(testing.io, testing.allocator, .{ .rows = rows, .cols = cols });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    t.cursorDown(rows - 1);

    for (rows..t.screens.active.pages.pages.first.?.capacity().rows) |_| {
        try t.index();
    }

    t.cursorRight(cols - 1);

    try testing.expectEqual(cols - 1, t.screens.active.cursor.x);
    try testing.expectEqual(rows - 1, t.screens.active.cursor.y);

    // क्‍ष
    try t.print(0x0915);
    try t.print(0x094D);
    try t.print(0x200D);
    try testing.expectEqual(cols - 1, t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    // This one increases the width to wide
    try t.print(0x0937);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(rows - 1, t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    {
        // Previous cell turns into spacer_head
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = cols - 1, .y = rows - 2 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        // Devanagari grapheme is wide
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = rows - 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x0915), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ 0x094D, 0x200D, 0x0937 }, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 1, .y = rows - 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: print invalid VS16 with second char (combining)" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/1482
    try t.print('n');
    try t.print(0xFE0F); // invalid VS16
    try t.print(0x0303); // combining tilde

    // We should have 1 cells taken up, and narrow.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'n'), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{'\u{0303}'}, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: overwrite grapheme should clear grapheme data" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x26C8); // Thunder cloud and rain
    try t.print(0xFE0E); // VS15 to make narrow
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    clearDirty(&t);

    t.setCursorPos(1, 1);
    try t.print('A');
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: overwrite multicodepoint grapheme clears grapheme data" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/289
    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // We should have one cell with graphemes
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());

    // Move back and overwrite wide
    t.setCursorPos(1, 1);
    clearDirty(&t);
    try t.print('X');
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), page.graphemeCount());

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X", str);
    }
}

test "Terminal: overwrite multicodepoint grapheme tail clears grapheme data" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/289
    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // We should have one cell with graphemes
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());

    // Move back and overwrite wide
    t.setCursorPos(1, 2);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" X", str);
    }

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), page.graphemeCount());
}

test "Terminal: print breaks valid grapheme cluster with Prepend + ASCII for speed" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);

    // Make sure we're not at cursor.x == 0 for the next char.
    try t.print('_');

    // U+0600 ARABIC NUMBER SIGN (Prepend)
    try t.print(0x0600);
    try t.print('1');

    // We should have 3 cells taken up, each narrow. Note that this is
    // **incorrect** grapheme break behavior, since a Prepend code point should
    // not break with the one following it per UAX #29 GB9b. However, as an
    // optimization we assume a grapheme break when c <= 255, and note that
    // this deviation only affects these very uncommon scenarios (e.g. the
    // Arabic number sign should precede Arabic-script digits).
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 3), t.screens.active.cursor.x);
    // This is what we'd expect if we did break correctly:
    //try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x0600), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        // This is what we'd expect if we did break correctly:
        //try testing.expect(cell.hasGrapheme());
        //try testing.expectEqualSlices(u21, &.{'1'}, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '1'), cell.content.codepoint.data);
        // This is what we'd expect if we did break correctly:
        //try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: print writes to bottom if scrolled" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 2 });
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    t.setCursorPos(0, 0);

    // Make newlines so we create scrollback
    // 3 pushes hello off the screen
    try t.index();
    try t.index();
    try t.index();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Scroll to the top
    t.screens.active.scroll(.{ .top = {} });
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }

    // Type
    try t.print('A');
    t.screens.active.scroll(.{ .active = {} });
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }

    try testing.expect(isDirty(&t, .{ .active = .{
        .x = t.screens.active.cursor.x,
        .y = t.screens.active.cursor.y,
    } }));
}

test "Terminal: print charset" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // G1 should have no effect
    t.configureCharset(.G1, .dec_special);
    t.configureCharset(.G2, .dec_special);
    t.configureCharset(.G3, .dec_special);

    // No dirty to configure charset
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    // Basic grid writing
    try t.print('`');
    t.configureCharset(.G0, .utf8);
    try t.print('`');
    t.configureCharset(.G0, .ascii);
    try t.print('`');
    t.configureCharset(.G0, .dec_special);
    try t.print('`');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("```◆", str);
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print charset outside of ASCII" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // G1 should have no effect
    t.configureCharset(.G1, .dec_special);
    t.configureCharset(.G2, .dec_special);
    t.configureCharset(.G3, .dec_special);

    // No dirty to configure charset
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    // Basic grid writing
    t.configureCharset(.G0, .dec_special);
    try t.print('`');
    try t.print(0x1F600);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("◆ ", str);
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print invoke charset" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    t.configureCharset(.G1, .dec_special);

    try t.print('`');

    // Invokecharset but should not mark dirty on its own
    clearDirty(&t);
    t.invokeCharset(.GL, .G1, false);
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    try t.print('`');
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    try t.print('`');
    t.invokeCharset(.GL, .G0, false);
    try t.print('`');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("`◆◆`", str);
    }
}

test "Terminal: print invoke charset single" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    t.configureCharset(.G1, .dec_special);

    // Basic grid writing
    try t.print('`');
    t.invokeCharset(.GL, .G1, true);
    try t.print('`');
    try t.print('`');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("`◆`", str);
    }
}

test "Terminal: print kitty unicode placeholder" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    try t.print(kitty.graphics.unicode.placeholder);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, kitty.graphics.unicode.placeholder), cell.content.codepoint.data);
        try testing.expect(list_cell.row.kitty_virtual_placeholder);
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: disabled wraparound with wide grapheme and half space" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    t.modes.set(.grapheme_cluster, true);
    t.modes.set(.wraparound, false);

    // This puts our cursor at the end and there is NO SPACE for a
    // wide character.
    try t.printString("AAAA");
    try t.print(0x2764); // Heart
    clearDirty(&t);
    try t.print(0xFE0F); // VS16 to make wide
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAA❤", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '❤'), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    // Should not be dirty since we didn't modify anything
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print right margin wrap" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);

    try t.printString("123456789");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 5);
    try t.printString("XY");

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1234X6789\n  Y", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
}

test "Terminal: print right margin wrap dirty tracking" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);

    try t.printString("123456789");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 5);

    // Writing our X on the first line should mark only that line dirty.
    clearDirty(&t);
    try t.print('X');
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 4, .y = 0 } }));
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 2, .y = 1 } }));

    // Writing our Y should wrap. It marks both rows dirty because the
    // cursor moved.
    clearDirty(&t);
    try t.print('Y');
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 4, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 2, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1234X6789\n  Y", str);
    }
}

test "Terminal: print right margin outside" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);

    try t.printString("123456789");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 6);
    clearDirty(&t);
    try t.printString("XY");

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("12345XY89", str);
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 5, .y = 0 } }));
}

test "Terminal: print right margin outside wrap" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);

    try t.printString("123456789");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 10);
    try t.printString("XY");

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123456789X\n  Y", str);
    }
}

test "Terminal: print wide char at right margin does not create spacer head" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 5);
    try t.print(0x1F600); // Smiley face
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);

    // Both rows dirty because the cursor moved
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 4, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 4, .y = 1 } }));

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);

        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F600), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: print with hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Setup our hyperlink and print
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("123456");

    // Verify all our cells have a hyperlink
    for (0..6) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print over cell with same hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Setup our hyperlink and print
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("123456");
    t.setCursorPos(1, 1);
    try t.printString("123456");

    // Verify all our cells have a hyperlink
    for (0..6) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print and end hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Setup our hyperlink and print
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("123");
    t.screens.active.endHyperlink();
    try t.printString("456");

    // Verify all our cells have a hyperlink
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    for (3..6) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print and change hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Setup our hyperlink and print
    try t.screens.active.startHyperlink("http://one.example.com", null);
    try t.printString("123");
    try t.screens.active.startHyperlink("http://two.example.com", null);
    try t.printString("456");

    // Verify all our cells have a hyperlink
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    for (3..6) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 2), id);
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

// Printing a wide char at the right edge with an active hyperlink causes
// printCell to write a spacer_head before printWrap sets the row wrap
// flag. The integrity check inside setHyperlink (or increaseCapacity)
// sees the unwrapped spacer head and panics. Found via fuzzing.
test "Terminal: print wide char at right edge with hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);

    try t.screens.active.startHyperlink("http://example.com", null);

    // Move cursor to the last column (1-indexed)
    t.setCursorPos(1, 10);

    // Print a wide character; this will call printCell(0, .spacer_head)
    // at the right edge before calling printWrap, triggering the
    // integrity violation.
    try t.print(0x4E2D); // U+4E2D '中'

    // Cursor wraps to row 2, after the wide char + spacer tail
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Row 0, col 9: spacer head with hyperlink
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 9, .y = 0 } }).?;
        try testing.expectEqual(Cell.Wide.spacer_head, list_cell.cell.wide);
        try testing.expect(list_cell.cell.hyperlink);
        try testing.expect(list_cell.row.wrap);
    }
    // Row 1, col 0: the wide char with hyperlink
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        try testing.expectEqual(@as(u21, 0x4E2D), list_cell.cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, list_cell.cell.wide);
        try testing.expect(list_cell.cell.hyperlink);
    }
    // Row 1, col 1: spacer tail with hyperlink
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        try testing.expectEqual(Cell.Wide.spacer_tail, list_cell.cell.wide);
        try testing.expect(list_cell.cell.hyperlink);
    }
}

test "Terminal: insertLines multi-codepoint graphemes" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Disable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();

    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\n👨‍👩‍👧\nGHI", str);
    }
}

test "Terminal: print with style marks the row as styled" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .bold = {} });
    try t.print('A');
    try t.setAttribute(.{ .unset = {} });
    try t.print('B');

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.row.styled);
    }
}

test "Terminal: DECALN resets graphemes with protected mode" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    // Add protected mode. A previous version of DECALN accidentally preserved
    // protected mode which left dangling managed memory.
    t.setProtectedMode(.iso);

    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    try t.decaln();

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.protected);
    try testing.expect(t.screens.active.protected_mode == .iso);

    for (0..t.rows) |y| try testing.expect(isDirty(&t, .{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("EEE\nEEE\nEEE", str);
    }
}

test "Terminal: insertBlanks deleting graphemes" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Disable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.printString("ABC");

    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    // We should have one cell with graphemes
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());

    t.setCursorPos(1, 1);
    clearDirty(&t);
    t.insertBlanks(4);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    A", str);
    }

    // We should have no graphemes
    try testing.expectEqual(@as(usize, 0), page.graphemeCount());
}

test "Terminal: insertBlanks shift graphemes" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.printString("A");

    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    // We should have one cell with graphemes
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());

    t.setCursorPos(1, 1);
    clearDirty(&t);
    t.insertBlanks(1);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" A👨‍👩‍👧", str);
    }

    // We should have no graphemes
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());
}

test "Terminal: printRepeat simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("A");
    try t.printRepeat(1);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AA", str);
    }
}

test "Terminal: printRepeat wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("    A");
    try t.printRepeat(1);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    A\nA", str);
    }
}

test "Terminal: printRepeat no previous character" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printRepeat(1);
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: printSlice simple ascii" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    try t.printSlice(&.{ 'h', 'e', 'l', 'l', 'o' });
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    try testing.expectEqual(@as(u21, 'o'), t.previous_char.?);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }
}

test "Terminal: printSlice charset batched fill" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    t.configureCharset(.G1, .dec_special);
    t.invokeCharset(.GL, .G1, false);
    t.modes.set(.grapheme_cluster, true);

    // Background-only cells use the general fill path.
    try t.setAttribute(.{ .@"8_bg" = .red });
    t.eraseDisplay(.complete, false);

    // Require batching when reusing cells and replacing styles.
    const cps = [_]u32{ 'l', 'q', 'q', 'q', 'k', 'm', 'q', 'q', 'q', 'j' };
    for ([_]sgr.Attribute{ .unset, .unset, .bold, .bold, .unset }) |attr| {
        t.setCursorPos(1, 1);
        try t.setAttribute(attr);
        try testing.expectEqual(cps.len, try printSliceFast(&t, &cps, true, false));
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("┌───┐\n└───┘", str);
        try testing.expectEqual(@as(u21, 'j'), t.previous_char.?);
        try testing.expect(t.screens.active.cursor.pending_wrap);
        for (0..2) |y| {
            for (0..5) |x| {
                const cell = t.screens.active.pages.getCell(.{ .active = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                } }).?.cell;
                try testing.expectEqual(t.screens.active.cursor.style_id, cell.style_id);
            }
        }
        try t.screens.active.cursor.page_pin.node.page().verifyIntegrity(alloc);
    }
}

test "Terminal: printSlice charset matches scalar printing" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    for ([_]charsets.Charset{ .dec_special, .british }) |set| {
        for ([_]bool{ false, true }) |grapheme_cluster| {
            var scalar = try init(io_impl, alloc, .{ .cols = 17, .rows = 4 });
            defer scalar.deinit(alloc);
            var batched = try init(io_impl, alloc, .{ .cols = 17, .rows = 4 });
            defer batched.deinit(alloc);

            for ([_]*Terminal{ &scalar, &batched }) |t| {
                t.configureCharset(.G0, set);
                t.modes.set(.grapheme_cluster, grapheme_cluster);
            }

            var bytes: [240]u32 = undefined;
            for (&bytes, 0x10..) |*cp, value| cp.* = @intCast(value);
            const mixed = [_]u32{ 0x100, 'q', 0x301, 'x', 0x4E00, '#', 0xFE0F, 0x1F600, 'j' };
            for ([_][]const u32{ &bytes, &mixed }) |cps| {
                for (cps) |cp| try scalar.print(@intCast(cp));
                try batched.printSlice(cps);

                const expected = try scalar.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
                defer alloc.free(expected);
                const actual = try batched.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
                defer alloc.free(actual);
                try testing.expectEqualStrings(expected, actual);
                try testing.expectEqual(scalar.screens.active.cursor.x, batched.screens.active.cursor.x);
                try testing.expectEqual(scalar.screens.active.cursor.y, batched.screens.active.cursor.y);
                try testing.expectEqual(scalar.screens.active.cursor.pending_wrap, batched.screens.active.cursor.pending_wrap);
                try testing.expectEqual(scalar.previous_char, batched.previous_char);
            }
        }
    }
}

test "Terminal: printSlice charset single shift and repeat" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    t.configureCharset(.G0, .dec_special);
    t.configureCharset(.G2, .british);
    t.invokeCharset(.GL, .G2, true);
    try t.printSlice(&.{ '#', 'q' });
    try testing.expectEqual(null, t.screens.active.charset.single_shift);
    try t.printRepeat(2);

    // REP uses the original byte with the current charset.
    t.configureCharset(.G0, .ascii);
    try t.printRepeat(2);
    const str = try t.plainString(alloc);
    defer alloc.free(str);
    try testing.expectEqualStrings("£───qq", str);
}

test "Terminal: printSlice wraps and scrolls" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    // 12 chars: fills row 1 (5), row 2 (5), wraps+scrolls, 2 more.
    try t.printSlice(&.{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l' });

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("fghij\nkl", str);
    }
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
}

test "Terminal: printSlice pending wrap state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    try t.printSlice(&.{ 'a', 'b', 'c', 'd', 'e' });
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("abcde", str);
    }
}

test "Terminal: printSlice differential fuzz vs print" {
    const alloc = testing.allocator;
    const io_impl = testing.io;

    // Multiple seeds and terminal sizes for coverage, including a
    // tiny terminal to stress wrap/scroll edge cases.
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    try testPrintSliceDifferential(io_impl, alloc, rand, 500, 80, 24);
    try testPrintSliceDifferential(io_impl, alloc, rand, 500, 10, 4);
    try testPrintSliceDifferential(io_impl, alloc, rand, 500, 5, 2);
    try testPrintSliceDifferential(io_impl, alloc, rand, 200, 2, 2);
}

test "Terminal: printAttributes" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    var storage: [64]u8 = undefined;

    {
        try t.setAttribute(.{ .direct_color_fg = .{ .r = 1, .g = 2, .b = 3 } });
        defer t.setAttribute(.unset) catch unreachable;
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings("0;38:2::1:2:3", buf);
    }

    {
        try t.setAttribute(.bold);
        try t.setAttribute(.{ .direct_color_bg = .{ .r = 1, .g = 2, .b = 3 } });
        defer t.setAttribute(.unset) catch unreachable;
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings("0;1;48:2::1:2:3", buf);
    }

    {
        try t.setAttribute(.bold);
        try t.setAttribute(.faint);
        try t.setAttribute(.italic);
        try t.setAttribute(.{ .underline = .single });
        try t.setAttribute(.blink);
        try t.setAttribute(.inverse);
        try t.setAttribute(.invisible);
        try t.setAttribute(.strikethrough);
        try t.setAttribute(.overline);
        try t.setAttribute(.{ .direct_color_fg = .{ .r = 100, .g = 200, .b = 255 } });
        try t.setAttribute(.{ .direct_color_bg = .{ .r = 101, .g = 102, .b = 103 } });
        defer t.setAttribute(.unset) catch unreachable;
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings("0;1;2;3;4;53;5;7;8;9;38:2::100:200:255;48:2::101:102:103", buf);
    }

    const Case = struct {
        underline: sgr.Attribute.Underline,
        expected: []const u8,
    };
    for ([_]Case{
        .{ .underline = .single, .expected = "0;4" },
        .{ .underline = .double, .expected = "0;4:2" },
        .{ .underline = .curly, .expected = "0;4:3" },
        .{ .underline = .dotted, .expected = "0;4:4" },
        .{ .underline = .dashed, .expected = "0;4:5" },
    }) |case| {
        try t.setAttribute(.{ .underline = case.underline });
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings(case.expected, buf);
    }

    try t.setAttribute(.unset);
    {
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings("0", buf);
    }
}

// https://github.com/mitchellh/ghostty/issues/272
// This is also tested in depth in screen resize tests but I want to keep
// this test around to ensure we don't regress at multiple layers.
test "Terminal: resize less cols with wide char then print" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    try t.print('x');
    try t.print('😀'); // 0x1F600
    try t.resize(alloc, .{ .cols = 2, .rows = 3 });
    t.setCursorPos(1, 2);
    try t.print('😀'); // 0x1F600
}
