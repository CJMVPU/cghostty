//! Terminal editing regression tests.
const support = @import("support.zig");
const testing = support.testing;
const hyperlink = support.hyperlink;
const style = support.style;
const Cell = support.Cell;
const init = support.init;
const isDirty = support.isDirty;
const clearDirty = support.clearDirty;

test "Terminal: eraseChars simple operation" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    clearDirty(&t);
    t.eraseChars(2);
    try t.print('X');

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X C", str);
    }
}

test "Terminal: eraseChars minimum one" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    clearDirty(&t);
    t.eraseChars(0);
    try t.print('X');
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBC", str);
    }
}

test "Terminal: eraseChars beyond screen edge" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("  ABC") |c| try t.print(c);
    t.setCursorPos(1, 4);
    t.eraseChars(10);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  A", str);
    }
}

test "Terminal: eraseChars wide character" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('橋');
    for ("BC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X BC", str);
    }
}

test "Terminal: eraseChars resets pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.eraseChars(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: eraseChars resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE123") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(row.wrap);
    }

    t.setCursorPos(1, 1);
    t.eraseChars(1);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }

    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBCDE\n123", str);
    }
}

test "Terminal: eraseChars preserves background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseChars(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
        {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
        {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 1, .y = 0 } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}

test "Terminal: eraseChars handles refcounted styles" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .bold = {} });
    try t.print('A');
    try t.print('B');
    try t.setAttribute(.{ .unset = {} });
    try t.print('C');

    // verify we have styles in our style map
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.styles.count());

    t.setCursorPos(1, 1);
    t.eraseChars(2);

    // verify we have no styles in our style map
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}

test "Terminal: eraseChars protected attributes respected with iso" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

test "Terminal: eraseChars protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 1);
    t.eraseChars(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

test "Terminal: eraseChars protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

test "Terminal: eraseChars wide char boundary conditions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 1, .cols = 8 });
    defer t.deinit(alloc);

    try t.printString("😀a😀b😀");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("😀a😀b😀", str);
    }

    t.setCursorPos(1, 2);
    t.eraseChars(3);
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();

    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("     b😀", str);
    }
}

test "Terminal: eraseChars wide char splits proper cell boundaries" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 1, .cols = 30 });
    defer t.deinit(alloc);

    // This is a test for a bug: https://github.com/ghostty-org/ghostty/issues/2817
    // To explain the setup:
    // (1) We need our wide characters starting on an even (1-based) column.
    // (2) We need our cursor to be in the middle somewhere.
    // (3) We need our count to be less than our cursor X and on a split cell.
    // The bug was that we split the wrong cell boundaries.

    try t.printString("x食べて下さい");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("x食べて下さい", str);
    }

    t.setCursorPos(1, 6); // At: て
    t.eraseChars(4); // Delete: て下
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();

    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("x食べ    さい", str);
    }
}

test "Terminal: eraseChars wide char wrap boundary conditions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 8 });
    defer t.deinit(alloc);

    try t.printString(".......😀abcde😀......");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(".......\n😀abcde\n😀......", str);

        const unwrapped = try t.plainStringUnwrapped(alloc);
        defer testing.allocator.free(unwrapped);
        try testing.expectEqualStrings(".......😀abcde😀......", unwrapped);
    }

    t.setCursorPos(2, 2);
    t.eraseChars(3);
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();

    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(".......\n    cde\n😀......", str);

        const unwrapped = try t.plainStringUnwrapped(alloc);
        defer testing.allocator.free(unwrapped);
        try testing.expectEqualStrings(".......     cde\n😀......", unwrapped);
    }
}

test "Terminal: eraseChars clearing wrapped wide char marks spacer head row dirty" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 5 });
    defer t.deinit(alloc);

    // The wide char doesn't fit so it wraps, leaving a spacer head at
    // the end of the first row.
    try t.printString("ABCD字");
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        try testing.expectEqual(Cell.Wide.spacer_head, list_cell.cell.wide);
        try testing.expect(list_cell.row.wrap);
    }

    t.setCursorPos(2, 1);
    clearDirty(&t);
    t.eraseChars(1);
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();

    // Erasing the wide char also clears the spacer head on the previous
    // row, so that row must be dirty too.
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 1 } }));
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 2 } }));

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        try testing.expectEqual(Cell.Wide.narrow, list_cell.cell.wide);
    }
}

test "Terminal: insertBlanks zero" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);

    t.insertBlanks(0);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

test "Terminal: insertBlanks" {
    // NOTE: this is not verified with conformance tests, so these
    // tests might actually be verifying wrong behavior.
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);

    clearDirty(&t);
    t.insertBlanks(2);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }
}

test "Terminal: insertBlanks pushes off end" {
    // NOTE: this is not verified with conformance tests, so these
    // tests might actually be verifying wrong behavior.
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 2 });
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);

    clearDirty(&t);
    t.insertBlanks(2);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  A", str);
    }
}

test "Terminal: insertBlanks more than size" {
    // NOTE: this is not verified with conformance tests, so these
    // tests might actually be verifying wrong behavior.
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 2 });
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);

    clearDirty(&t);
    t.insertBlanks(5);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: insertBlanks preserves background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.insertBlanks(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
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

test "Terminal: insertBlanks shift off screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);

    for ("  ABC") |c| try t.print(c);
    t.setCursorPos(1, 3);
    clearDirty(&t);
    t.insertBlanks(2);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X A", str);
    }
}

test "Terminal: insertBlanks split multi-cell character" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);

    for ("123") |c| try t.print(c);
    try t.print('橋');
    t.setCursorPos(1, 1);
    clearDirty(&t);
    t.insertBlanks(1);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" 123", str);
    }
}

test "Terminal: insertBlanks split multi-cell character from tail" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("橋123");
    t.setCursorPos(1, 2);
    t.insertBlanks(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("   12", str);
    }
}

test "Terminal: insertBlanks shifts hyperlinks" {
    // osc "8;;http://example.com"
    // printf "link"
    // printf "\r"
    // csi "3@"
    // echo
    //
    // link should be preserved, blanks should not be linked

    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC");
    t.setCursorPos(1, 1);
    t.insertBlanks(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }

    // Verify all our cells have a hyperlink
    for (2..5) |x| {
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
    for (0..2) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}

test "Terminal: insertBlanks pushes hyperlink off end completely" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 2 });
    defer t.deinit(alloc);

    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC");
    t.setCursorPos(1, 1);
    t.insertBlanks(3);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}

test "Terminal: deleteChars" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    clearDirty(&t);
    t.deleteChars(2);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ADE", str);
    }
}

test "Terminal: deleteChars zero count" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    clearDirty(&t);
    t.deleteChars(0);
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE", str);
    }
}

test "Terminal: deleteChars more than half" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    clearDirty(&t);
    t.deleteChars(3);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AE", str);
    }
}

test "Terminal: deleteChars more than line width" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    clearDirty(&t);
    t.deleteChars(10);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: deleteChars should shift left" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    clearDirty(&t);
    t.deleteChars(1);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ACDE", str);
    }
}

test "Terminal: deleteChars resets pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.deleteChars(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: deleteChars resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE123") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(row.wrap);
    }
    t.setCursorPos(1, 1);
    t.deleteChars(1);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }

    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XCDE\n123", str);
    }
}

test "Terminal: deleteChars simple operation" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.setCursorPos(1, 3);

    clearDirty(&t);
    t.deleteChars(2);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB23", str);
    }
}

test "Terminal: deleteChars preserves background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    for ("ABC123") |c| try t.print(c);
    t.setCursorPos(1, 3);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.deleteChars(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB23", str);
    }
    for (t.cols - 2..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: deleteChars split wide character from spacer tail" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("A橋123");
    t.setCursorPos(1, 3);
    t.deleteChars(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A 123", str);
    }
}

test "Terminal: deleteChars split wide character from wide" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("橋123");
    t.setCursorPos(1, 1);
    t.deleteChars(1);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '1'), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: deleteChars split wide character from end" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("A橋123");
    t.setCursorPos(1, 1);
    t.deleteChars(1);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x6A4B), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: deleteChars with a spacer head at the end" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("0123橋123");
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const row = list_cell.row;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
        try testing.expect(row.wrap);
    }

    t.setCursorPos(1, 1);
    t.deleteChars(1);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: deleteChars split wide character tail" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(1, t.cols - 1);
    try t.print(0x6A4B); // 橋
    t.carriageReturn();
    t.deleteChars(t.cols - 1);
    try t.print('0');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("0", str);
    }
}

test "Terminal: deleteChars wide char boundary conditions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 1, .cols = 8 });
    defer t.deinit(alloc);

    // EXPLANATION(qwerasd):
    //
    // There are 3 or 4 boundaries to be concerned with in deleteChars,
    // depending on how you count them. Consider the following terminal:
    //
    //   +--------+
    // 0 |.ABCDEF.|
    //   : ^      : (^ = cursor)
    //   +--------+
    //
    // if we DCH 3 we get
    //
    //   +--------+
    // 0 |.DEF....|
    //   +--------+
    //
    // The boundaries exist at the following points then:
    //
    //   +--------+
    // 0 |.ABCDEF.|
    //   :11 22 33:
    //   +--------+
    //
    // I'm counting 2 for double since it's both the end of the deleted
    // content and the start of the content that is shifted in to place.
    //
    // Now consider wide characters (represented as `WW`) at these boundaries:
    //
    //   +--------+
    // 0 |WWaWWbWW|
    //   : ^      : (^ = cursor)
    //   : ^^^    : (^ = deleted by DCH 3)
    //   +--------+
    //
    // -> DCH 3
    // -> The first 2 wide characters are split & destroyed (verified in xterm)
    //
    //   +--------+
    // 0 |..bWW...|
    //   +--------+

    try t.printString("😀a😀b😀");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("😀a😀b😀", str);
    }

    t.setCursorPos(1, 2);
    t.deleteChars(3);
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();

    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  b😀", str);
    }
}

test "Terminal: deleteChars wide char wrap boundary conditions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 8 });
    defer t.deinit(alloc);

    // EXPLANATION(qwerasd):
    // (cont. from "Terminal: deleteChars wide char boundary conditions")
    //
    // Additionally consider soft-wrapped wide chars (`H` = spacer head):
    //
    //   +--------+
    // 0 |.......H…
    // 1 …WWabcdeH…
    //   : ^      : (^ = cursor)
    //   : ^^^    : (^ = deleted by DCH 3)
    // 2 …WW......|
    //   +--------+
    //
    // -> DCH 3
    // -> First wide character split and destroyed, including spacer head,
    //    second spacer head removed (verified in xterm).
    // -> Wrap state of row reset
    //
    //   +--------+
    // 0 |........|
    // 1 |.cde....|
    // 2 |WW......|
    //   +--------+
    //

    try t.printString(".......😀abcde😀......");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(".......\n😀abcde\n😀......", str);

        const unwrapped = try t.plainStringUnwrapped(alloc);
        defer testing.allocator.free(unwrapped);
        try testing.expectEqualStrings(".......😀abcde😀......", unwrapped);
    }

    t.setCursorPos(2, 2);
    clearDirty(&t);
    t.deleteChars(3);
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();

    // Deleting the wide char also clears the spacer head on the previous
    // row, so that row must be dirty too.
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 1 } }));
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(".......\n cde\n😀......", str);

        const unwrapped = try t.plainStringUnwrapped(alloc);
        defer testing.allocator.free(unwrapped);
        try testing.expectEqualStrings(".......  cde\n😀......", unwrapped);
    }
}

test "Terminal: eraseLine simple erase right" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    clearDirty(&t);
    t.eraseLine(.right, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB", str);
    }
}

test "Terminal: eraseLine resets pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.eraseLine(.right, false);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDB", str);
    }
}

test "Terminal: eraseLine resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE123") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.row.wrap);
    }

    t.setCursorPos(1, 1);
    t.eraseLine(.right, false);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(!list_cell.row.wrap);
    }
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\n123", str);
    }
}

test "Terminal: eraseLine right preserves background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseLine(.right, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
        for (1..5) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}

test "Terminal: eraseLine right wide character" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    for ("AB") |c| try t.print(c);
    try t.print('橋');
    for ("DE") |c| try t.print(c);
    t.setCursorPos(1, 4);
    clearDirty(&t);
    t.eraseLine(.right, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB", str);
    }
}

test "Terminal: eraseLine right protected attributes respected with iso" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    clearDirty(&t);
    t.eraseLine(.right, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

test "Terminal: eraseLine right protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    clearDirty(&t);
    t.eraseLine(.right, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: eraseLine right protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    clearDirty(&t);
    t.eraseLine(.right, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: eraseLine right protected requested" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    for ("12345678") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 4);
    clearDirty(&t);
    t.eraseLine(.right, true);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123  X", str);
    }
}

test "Terminal: eraseLine simple erase left" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    clearDirty(&t);
    t.eraseLine(.left, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("   DE", str);
    }
}

test "Terminal: eraseLine left resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    clearDirty(&t);
    t.eraseLine(.left, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    B", str);
    }
}

test "Terminal: eraseLine left preserves background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseLine(.left, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  CDE", str);
        for (0..2) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}

test "Terminal: eraseLine left wide character" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    for ("AB") |c| try t.print(c);
    try t.print('橋');
    for ("DE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    clearDirty(&t);
    t.eraseLine(.left, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    DE", str);
    }
}

test "Terminal: eraseLine left protected attributes respected with iso" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    clearDirty(&t);
    t.eraseLine(.left, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

test "Terminal: eraseLine left protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    clearDirty(&t);
    t.eraseLine(.left, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

test "Terminal: eraseLine left protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    clearDirty(&t);
    t.eraseLine(.left, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

test "Terminal: eraseLine left protected requested" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 8);
    clearDirty(&t);
    t.eraseLine(.left, true);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("     X  9", str);
    }
}

test "Terminal: eraseLine complete preserves background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseLine(.complete, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
        for (0..5) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}

test "Terminal: eraseLine complete resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE123") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.row.wrap);
    }

    t.setCursorPos(1, 1);
    t.eraseLine(.complete, false);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(!list_cell.row.wrap);
    }
    try t.print('X');
    try t.resize(alloc, .{ .rows = 5, .cols = 10 });

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\n123", str);
    }
}

test "Terminal: eraseLine complete protected attributes respected with iso" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    clearDirty(&t);
    t.eraseLine(.complete, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

test "Terminal: eraseLine complete protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    clearDirty(&t);
    t.eraseLine(.complete, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: eraseLine complete protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    clearDirty(&t);
    t.eraseLine(.complete, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: eraseLine complete protected requested" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 8);
    clearDirty(&t);
    t.eraseLine(.complete, true);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("     X", str);
    }
}

test "Terminal: tabClear single" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 30, .rows = 5 });
    defer t.deinit(alloc);

    t.horizontalTab();
    t.tabClear(.current);
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    t.setCursorPos(1, 1);
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 16), t.screens.active.cursor.x);
}

test "Terminal: tabClear all" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 30, .rows = 5 });
    defer t.deinit(alloc);

    t.tabClear(.all);
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    t.setCursorPos(1, 1);
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 29), t.screens.active.cursor.x);
}

test "Terminal: eraseDisplay simple erase below" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);

    clearDirty(&t);
    t.eraseDisplay(.below, false);

    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}

test "Terminal: eraseDisplay erase below preserves SGR bg" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);

    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseDisplay(.below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
        for (1..5) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}

test "Terminal: eraseDisplay below split multi-cell" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("AB橋C");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DE橋F");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GH橋I");
    t.setCursorPos(2, 4);
    t.eraseDisplay(.below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB橋C\nDE", str);
    }
}

test "Terminal: eraseDisplay below protected attributes respected with iso" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: eraseDisplay below protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}

test "Terminal: eraseDisplay below protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}

test "Terminal: eraseDisplay below protected attributes respected with force" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.below, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: eraseDisplay simple erase above" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);

    clearDirty(&t);
    t.eraseDisplay(.above, false);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}

test "Terminal: eraseDisplay erase above preserves SGR bg" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);

    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseDisplay(.above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
        for (0..2) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}

test "Terminal: eraseDisplay above split multi-cell" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("AB橋C");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DE橋F");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GH橋I");
    t.setCursorPos(2, 3);
    t.eraseDisplay(.above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n    F\nGH橋I", str);
    }
}

test "Terminal: eraseDisplay above protected attributes respected with iso" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: eraseDisplay above protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}

test "Terminal: eraseDisplay above protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}

test "Terminal: eraseDisplay above protected attributes respected with force" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.above, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: eraseDisplay protected complete" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 4);

    clearDirty(&t);
    t.eraseDisplay(.complete, true);
    for (0..t.rows) |y| try testing.expect(isDirty(&t, .{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n     X", str);
    }
}

test "Terminal: eraseDisplay protected below" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 4);
    t.eraseDisplay(.below, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n123  X", str);
    }
}

test "Terminal: eraseDisplay protected above" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 8);
    t.eraseDisplay(.above, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n     X  9", str);
    }
}

test "Terminal: eraseDisplay complete preserves cursor" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Set our cursur
    try t.setAttribute(.{ .bold = {} });
    try t.printString("AAAA");
    try testing.expect(t.screens.active.cursor.style_id != style.default_id);

    // Erasing the display may detect that our style is no longer in use
    // and prune our style, which we don't want because its still our
    // active cursor.
    t.eraseDisplay(.complete, false);
    try testing.expect(t.screens.active.cursor.style_id != style.default_id);
}

test "Terminal: OSC133C at x=0 on prompt row clears prompt mark" {
    // This tests the second Fish heuristic: when Fish emits a newline
    // then immediately sends OSC133C (start output) at column 0, we
    // should clear the prompt continuation mark we just set.
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Start a prompt
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ echo \\") |c| try t.print(c);

    // Simulate Fish behavior: newline first (which marks next row as prompt)
    t.carriageReturn();
    try t.linefeed();

    // Verify the new row is marked as prompt continuation
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }

    // Now Fish sends OSC133C at column 0 (cursor is still at x=0)
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try t.semanticPrompt(.init(.end_input_start_output));

    // The prompt continuation should be cleared
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.none, list_cell.row.semantic_prompt);
    }
}

test "Terminal: OSC133C at x>0 on prompt row does not clear prompt mark" {
    // If we're not at column 0, we shouldn't clear the prompt mark
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Start a prompt on a row
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);

    // Move to a new line and mark it as prompt continuation manually
    t.carriageReturn();
    try t.linefeed();
    try t.semanticPrompt(.{
        .action = .prompt_start,
        .options_unvalidated = "k=c",
    });
    for ("> ") |c| try t.print(c);

    // Verify the row is marked as prompt continuation
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }

    // Now send OSC133C but cursor is NOT at column 0
    try testing.expect(t.screens.active.cursor.x > 0);
    try t.semanticPrompt(.init(.end_input_start_output));

    // The prompt continuation should NOT be cleared (we're not at x=0)
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
}

// https://github.com/mitchellh/ghostty/issues/1607
test "Terminal: fullReset clears alt screen kitty keyboard state" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    try t.switchScreenMode(.@"1049", true);
    t.screens.active.kitty_keyboard.push(.{
        .disambiguate = true,
        .report_events = false,
        .report_alternates = true,
        .report_all = true,
        .report_associated = true,
    });
    try t.switchScreenMode(.@"1049", false);

    t.fullReset();
    try testing.expect(t.screens.get(.alternate) == null);
}

test "Terminal: eraseDisplay complete ignores stale prompt on recycled row" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    // Screen content that must NOT enter the scrollback on a clear.
    try t.printString("hello");

    // Mark row 1 as a prompt row and then discard it with a region
    // scroll, recycling its storage as the blank bottom row.
    t.screens.active.pages.getCell(
        .{ .active = .{ .y = 1 } },
    ).?.row.semantic_prompt = .prompt;
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(3, 1);
    try t.linefeed();
    t.setTopAndBottomMargin(0, 0);

    // ED2: since no prompt is on screen, this must NOT take the
    // scroll-and-clear path that pushes content into scrollback. A
    // stale prompt flag on the recycled blank bottom row would.
    t.eraseDisplay(.complete, false);

    try testing.expectEqual(t.screens.active.pages.rows, t.screens.active.pages.total_rows);
}
