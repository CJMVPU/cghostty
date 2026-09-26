//! Terminal scrolling regression tests.
const support = @import("support.zig");
const std = support.std;
const testing = support.testing;
const hyperlink = support.hyperlink;
const size = support.size;
const PageList = support.PageList;
const Page = support.Page;
const Cell = support.Cell;
const init = support.init;
const isDirty = support.isDirty;
const clearDirty = support.clearDirty;

test "Terminal forwards optional scrollback limits" {
    const max_lines: usize = 123;
    var t = try init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = max_lines,
    });
    defer t.deinit(testing.allocator);

    try testing.expectEqual(
        std.math.maxInt(usize),
        t.screens.active.pages.limits.bytes.explicit,
    );
    try testing.expectEqual(
        max_lines,
        t.screens.active.pages.limits.lines.explicit,
    );
}

test "Terminal setScrollbackMaxBytes" {
    var t = try init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 3,
        .max_scrollback_bytes = null,
    });
    defer t.deinit(testing.allocator);

    const primary = t.screens.get(.primary).?;
    const page_rows: usize = primary.pages.pages.first.?.capacity().rows;

    // Build several complete pages of history so lowering the byte limit has
    // existing allocations to prune immediately.
    for (0..4 * page_rows) |_| try t.linefeed();
    const old_page_size = primary.pages.page_size;
    t.setScrollbackMaxBytes(1);
    try testing.expectEqual(@as(usize, 1), primary.pages.limits.bytes.explicit);
    try testing.expect(primary.pages.page_size < old_page_size);
    try testing.expect(
        primary.pages.page_size <= primary.pages.limits.max(.bytes),
    );
    try testing.expect(!primary.no_scrollback);

    // Zero switches Screen behavior as well as PageList accounting, discards
    // all retained history, and prevents future linefeeds from recreating it.
    t.setScrollbackMaxBytes(0);
    try testing.expectEqual(@as(usize, 0), primary.pages.limits.bytes.explicit);
    try testing.expect(primary.no_scrollback);
    try testing.expectEqual(
        @as(usize, primary.pages.rows),
        primary.pages.total_rows,
    );
    try testing.expect(primary.pages.viewport == .active);

    for (0..page_rows) |_| try t.linefeed();
    try testing.expectEqual(
        @as(usize, primary.pages.rows),
        primary.pages.total_rows,
    );

    // Re-enabling unlimited scrollback affects subsequent output.
    t.setScrollbackMaxBytes(null);
    try testing.expectEqual(
        std.math.maxInt(usize),
        primary.pages.limits.bytes.explicit,
    );
    try testing.expect(!primary.no_scrollback);
    for (0..page_rows) |_| try t.linefeed();
    try testing.expect(primary.pages.total_rows > primary.pages.rows);
}

test "Terminal setScrollbackMaxLines" {
    var t = try init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 3,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    defer t.deinit(testing.allocator);

    const primary = t.screens.get(.primary).?;
    const page_rows: usize = primary.pages.pages.first.?.capacity().rows;

    for (0..4 * page_rows) |_| try t.linefeed();
    const old_total_rows = primary.pages.total_rows;
    t.setScrollbackMaxLines(page_rows);
    try testing.expectEqual(
        page_rows,
        primary.pages.limits.lines.explicit,
    );
    try testing.expect(primary.pages.total_rows < old_total_rows);
    try testing.expect(
        !primary.pages.limits.exceeded(&primary.pages, .lines),
    );

    const limited_total_rows = primary.pages.total_rows;
    t.setScrollbackMaxLines(null);
    try testing.expectEqual(
        std.math.maxInt(usize),
        primary.pages.limits.lines.explicit,
    );
    try testing.expectEqual(limited_total_rows, primary.pages.total_rows);
    for (0..3 * page_rows) |_| try t.linefeed();
    try testing.expect(
        primary.pages.total_rows - primary.pages.rows > page_rows,
    );
}

test "Terminal setScrollback only affects primary screen" {
    var t = try init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 3,
    });
    defer t.deinit(testing.allocator);

    _ = try t.switchScreen(.alternate);
    const primary = t.screens.get(.primary).?;
    const alternate = t.screens.get(.alternate).?;

    t.setScrollbackMaxBytes(123);
    t.setScrollbackMaxLines(456);

    try testing.expectEqual(
        @as(usize, 123),
        primary.pages.limits.bytes.explicit,
    );
    try testing.expectEqual(
        @as(usize, 456),
        primary.pages.limits.lines.explicit,
    );
    try testing.expect(!primary.no_scrollback);

    try testing.expectEqual(
        @as(usize, 0),
        alternate.pages.limits.bytes.explicit,
    );
    try testing.expectEqual(
        std.math.maxInt(usize),
        alternate.pages.limits.lines.explicit,
    );
    try testing.expect(alternate.no_scrollback);
    try testing.expectEqual(alternate, t.screens.active);
}

test "Terminal: input that forces scroll" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 1, .rows = 5 });
    defer t.deinit(alloc);

    // Basic grid writing
    for ("abcdef") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("b\nc\nd\ne\nf", str);
    }
}

// A cursor style or hyperlink ID is an index into a set stored in the
// page memory of the page the cursor pin points at. When scrollClear
// (here via ED 22, kitty's scroll_complete) pushes the active area onto
// a later page while the cursor pin is still on an earlier one,
// cursorReload must migrate the cursor's style and hyperlink references
// to the destination page. It previously replaced the pin directly,
// leaving the cursor holding an ID that was dead or aliased an unrelated
// entry on the new page, and the next print attached a live cell to it.
// Found via fuzzing.
test "Terminal: scrollClear across pages keeps cursor hyperlink refs page-local" {
    const alloc = testing.allocator;

    // Minimized from a 774-byte AFL fuzz input. Reading it:
    //
    //   A                 print, so REP has something to repeat
    //   ESC [ 48111 b     REP, filling the page and spilling onto a second
    //   ESC ] 8 ; ; 0x93  OSC 8; the C1 byte terminates the OSC and makes
    //                     the URI non-empty, so a hyperlink starts
    //   ESC [ 11 A        CUU, moving the cursor back onto the first page
    //   ESC [ 22 J        ED 22, i.e. scroll_complete -> Screen.scrollClear
    //   B                 print, which attaches the cursor hyperlink
    //   ESC ] 8 ; ; ESC   OSC 8 with an empty URI, ending the hyperlink
    //
    // The grid must be wide enough to fill a page from a single REP, so
    // this does not reproduce at 80x24.
    const input = "A\x1b[48111b\x1b]8;;\x93\x1b[11A\x1b[22JB\x1b]8;;\x1b";

    var t = try init(testing.io, alloc, .{ .cols = 200, .rows = 50 });
    defer t.deinit(alloc);

    {
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice(input);
    }

    // With slow runtime safety on, the page integrity checks during the
    // stream above already catch the bug. Verify the ref counts explicitly
    // as well so this test is meaningful with runtime safety off: every
    // cell holding a hyperlink ID owns a reference, so a count below the
    // number of holding cells means a live cell points at an entry that
    // was already freed.
    var node_ = t.screens.active.pages.pages.first;
    while (node_) |node| : (node_ = node.next) {
        const page = node.page();
        const cap = page.hyperlink_set.layout.cap;
        if (cap == 0) continue;

        const holders = try alloc.alloc(u32, cap);
        defer alloc.free(holders);
        @memset(holders, 0);

        for (page.rows.ptr(page.memory)[0..page.size.rows]) |*row| {
            if (!row.hyperlink) continue;
            for (row.cells.ptr(page.memory)[0..page.size.cols]) |*cell| {
                if (!cell.hyperlink) continue;
                const id = page.lookupHyperlink(cell) orelse continue;
                if (id < cap) holders[id] += 1;
            }
        }

        for (holders, 0..) |held, id| {
            if (held == 0) continue;
            const refs = page.hyperlink_set.refCount(page.memory, @intCast(id));
            try testing.expect(refs >= held);
        }
    }

    // If the cursor still has an active hyperlink, its own extra
    // reference must live on the cursor's page.
    const cursor = &t.screens.active.cursor;
    if (cursor.hyperlink_id != 0) {
        const page = cursor.page_pin.node.page();
        try testing.expect(
            page.hyperlink_set.refCount(page.memory, cursor.hyperlink_id) > 0,
        );
    }
}

test "Terminal: linefeed and carriage return" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Print and CR.
    for ("hello") |c| try t.print(c);
    clearDirty(&t);
    t.carriageReturn();

    // CR should not mark row dirty because it doesn't change rendering.
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    try t.linefeed();

    // LF marks row dirty due to cursor movement
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 1 } }));

    for ("world") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello\nworld", str);
    }
}

test "Terminal: linefeed unsets pending wrap" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap == true);
    clearDirty(&t);
    try t.linefeed();
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.screens.active.cursor.pending_wrap == false);
}

test "Terminal: linefeed mode automatic carriage return" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    // Basic grid writing
    t.modes.set(.linefeed, true);
    try t.printString("123456");
    try t.linefeed();
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123456\nX", str);
    }
}

test "Terminal: carriage return origin mode moves to left margin" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);

    t.modes.set(.origin, true);
    t.screens.active.cursor.x = 0;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
}

test "Terminal: carriage return left of left margin moves to zero" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);

    t.screens.active.cursor.x = 1;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
}

test "Terminal: carriage return right of left margin moves to left margin" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);

    t.screens.active.cursor.x = 3;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
}

test "Terminal: horizontal tabs with right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    t.scrolling_region.left = 2;
    t.scrolling_region.right = 5;
    t.setCursorPos(t.screens.active.cursor.y, 1);
    try t.print('X');
    t.horizontalTab();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X    A", str);
    }
}

test "Terminal: horizontal tabs with left margin in origin mode" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    t.modes.set(.origin, true);
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 5;
    t.setCursorPos(1, 2);
    try t.print('X');
    t.horizontalTabBack();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  AX", str);
    }
}

test "Terminal: horizontal tab back with cursor before left margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    t.modes.set(.origin, true);
    t.saveCursor();
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(5, 0);
    t.restoreCursor();
    t.horizontalTabBack();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X", str);
    }
}

test "Terminal: cursorPos limits with full scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.scrolling_region.top = 2;
    t.scrolling_region.bottom = 3;
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.modes.set(.origin, true);
    t.setCursorPos(500, 500);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n    X", str);
    }
}

test "Terminal: setTopAndBottomMargin simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(0, 0);

    clearDirty(&t);
    t.scrollDown(1);

    // Mark the rows we moved as dirty.
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

test "Terminal: setTopAndBottomMargin top only" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(2, 0);

    clearDirty(&t);
    t.scrollDown(1);

    // This is dirty because the cursor moves from this row
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }
}

test "Terminal: setTopAndBottomMargin top and bottom" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(1, 2);

    clearDirty(&t);
    t.scrollDown(1);

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nGHI", str);
    }
}

test "Terminal: setTopAndBottomMargin top equal to bottom" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(2, 2);

    clearDirty(&t);
    t.scrollDown(1);

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

test "Terminal: setLeftAndRightMargin simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(0, 0);

    clearDirty(&t);
    t.eraseChars(1);

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" BC\nDEF\nGHI", str);
    }
}

test "Terminal: setLeftAndRightMargin left only" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 0);
    try testing.expectEqual(@as(usize, 1), t.scrolling_region.left);
    try testing.expectEqual(@as(usize, t.cols - 1), t.scrolling_region.right);
    t.setCursorPos(1, 2);

    clearDirty(&t);
    t.insertLines(1);

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nDBC\nGEF\n HI", str);
    }
}

test "Terminal: setLeftAndRightMargin left and right" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(1, 2);
    t.setCursorPos(1, 2);

    clearDirty(&t);
    t.insertLines(1);

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C\nABF\nDEI\nGH", str);
    }
}

test "Terminal: setLeftAndRightMargin left equal right" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 2);
    t.setCursorPos(1, 2);

    clearDirty(&t);
    t.insertLines(1);

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

test "Terminal: setLeftAndRightMargin mode 69 unset" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, false);
    t.setLeftAndRightMargin(1, 2);
    t.setCursorPos(1, 2);

    clearDirty(&t);
    t.insertLines(1);

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

test "Terminal: insertLines simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);

    const node = t.screens.active.cursor.page_pin.node;
    const serial = node.serial;
    clearDirty(&t);
    t.insertLines(1);
    try testing.expect(!t.screens.active.pages.nodeIsValid(node, serial));

    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }
}

test "Terminal: insertLines colors with bg color" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);

    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }

    for (0..t.cols) |x| {
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

test "Terminal: insertLines handles style refs" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();

    // For the line being deleted, create a refcounted style
    try t.setAttribute(.{ .bold = {} });
    try t.printString("GHI");
    try t.setAttribute(.{ .unset = {} });

    // verify we have styles in our style map
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.styles.count());

    t.setCursorPos(2, 2);
    t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF", str);
    }

    // verify we have no styles in our style map
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}

test "Terminal: insertLines outside of scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(3, 4);
    t.setCursorPos(2, 2);

    clearDirty(&t);
    t.insertLines(1);

    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: insertLines top/bottom scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("123");
    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(2, 2);

    clearDirty(&t);
    t.insertLines(1);

    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\n123", str);
    }
}

test "Terminal: insertLines across page boundary marks all shifted rows dirty" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 10, .max_scrollback_bytes = 1024 });
    defer t.deinit(alloc);

    const first_page = t.screens.active.pages.pages.first.?;
    const first_page_nrows = first_page.capacity().rows;

    // Fill up the first page minus 3 rows
    for (0..first_page_nrows - 3) |_| try t.linefeed();

    // Add content that will cross a page boundary
    try t.printString("1AAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("2BBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("3CCCC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("4DDDD");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("5EEEE");

    // Verify we now have a second page
    const second_page = first_page.next.?;
    const first_serial = first_page.serial;
    const second_serial = second_page.serial;

    t.setCursorPos(1, 1);
    clearDirty(&t);
    t.insertLines(1);
    try testing.expect(!t.screens.active.pages.nodeIsValid(first_page, first_serial));
    try testing.expect(!t.screens.active.pages.nodeIsValid(second_page, second_serial));

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 4 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n1AAAA\n2BBBB\n3CCCC\n4DDDD", str);
    }
}

test "Terminal: insertLines hyperlink-dense row crosses page boundary" {
    // Regression test for the cross-page copy of insertLines: when the
    // shifted row carries more unique hyperlinks than the destination
    // page's hyperlink capacity, the copy must increase the destination
    // page's capacity and retry rather than corrupting the page list.
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 10, .max_scrollback_bytes = 1024 });
    defer t.deinit(alloc);

    const pages = &t.screens.active.pages;

    // Fill the first page so it is exactly full, then two more rows so
    // the second page holds the last two active rows (y=3 and y=4).
    const first_page_rows = pages.pages.first.?.capacity().rows;
    for (0..first_page_rows + 1) |_| try t.linefeed();
    try testing.expect(pages.pages.first != pages.pages.last);
    try testing.expectEqual(@as(usize, 2), pages.pages.last.?.rows());

    // Marker rows so we can verify the shift afterwards.
    t.setCursorPos(1, 1);
    try t.printString("0");
    t.setCursorPos(2, 1);
    try t.printString("1");
    t.setCursorPos(4, 1);
    try t.printString("3");
    t.setCursorPos(5, 1);
    try t.printString("4");

    // Fill the last row of the first page (active y=2) with unique
    // hyperlinks: more than the second page can hold with its default
    // hyperlink capacity. Writing them grows the first page's capacity
    // as needed; the second page keeps its default capacity.
    t.setCursorPos(3, 1);
    for (0..10) |i| {
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{i});
        try t.screens.active.startHyperlink(uri, null);
        try t.print(@intCast('A' + i));
        t.screens.active.endHyperlink();
    }
    {
        const pin = pages.pin(.{ .active = .{ .y = 2 } }).?;
        try testing.expectEqual(pages.pages.first.?, pin.node);
        try testing.expectEqual(pin.node.rows() - 1, @as(usize, pin.y));
    }
    try testing.expect(pages.pages.last.?.page().hyperlink_set.layout.cap < 10);

    // Insert a line at the top: every row shifts down by one and the
    // dense row crosses the page boundary into the second page.
    t.setCursorPos(1, 1);
    t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n0\n1\nABCDEFGHIJ\n3", str);
    }

    // The second page's hyperlink capacity had to grow to receive the
    // row, proving the capacity-retry path ran.
    try testing.expect(pages.pages.last.?.page().hyperlink_set.layout.cap >= 10);

    // Every cell of the dense row must still resolve to a real
    // hyperlink entry with the correct URI. A half-applied shift
    // leaves cells whose hyperlink flag is set but that have no map
    // entry, which aborts in clearCells later.
    for (0..10) |x| {
        const list_cell = pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 3,
        } }).?;
        try testing.expect(list_cell.cell.hyperlink);
        const page: *Page = list_cell.node.page();
        const id = page.lookupHyperlink(list_cell.cell).?;
        const link = page.hyperlink_set.get(page.memory, id);
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{x});
        try testing.expectEqualStrings(uri, link.uri.slice(page.memory));
    }

    // All pages must pass integrity checks.
    var node_: ?*PageList.List.Node = pages.pages.first;
    while (node_) |node| : (node_ = node.next) node.page().assertIntegrity();
}

test "Terminal: insertLines (legacy test)" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    try t.print('E');

    // Move to row 2
    t.setCursorPos(2, 1);

    // Insert two lines
    t.insertLines(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\nB\nC", str);
    }
}

test "Terminal: insertLines zero" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    // This should do nothing
    t.setCursorPos(1, 1);
    t.insertLines(0);
}

test "Terminal: insertLines with scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 6 });
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    try t.print('E');

    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(1, 1);

    clearDirty(&t);
    t.insertLines(1);

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));

    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nA\nC\nD\nE", str);
    }
}

test "Terminal: insertLines more than remaining" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    try t.print('E');

    // Move to row 2
    t.setCursorPos(2, 1);

    // Insert a bunch of  lines
    clearDirty(&t);
    t.insertLines(20);

    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: insertLines resets pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.insertLines(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nABCDE", str);
    }
}

test "Terminal: insertLines resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    try t.print('1');
    t.carriageReturn();
    try t.linefeed();
    for ("ABCDEF") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.insertLines(1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\n1\nABC", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 2 } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
}

test "Terminal: insertLines left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);

    clearDirty(&t);
    t.insertLines(1);

    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123\nD   56\nGEF489\n HI7", str);
    }
}

test "Terminal: scrollUp simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);

    const cursor = t.screens.active.cursor;
    const viewport_before = t.screens.active.pages.getTopLeft(.viewport);
    try t.scrollUp(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);

    // Viewport should have moved. Our entire page should've scrolled!
    // The viewport moving will cause our render state to make the full
    // frame as dirty.
    const viewport_after = t.screens.active.pages.getTopLeft(.viewport);
    try testing.expect(!viewport_before.eql(viewport_after));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("DEF\nGHI", str);
    }
}

test "Terminal: scrollUp moves hyperlink" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("DEF");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    try t.scrollUp(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("DEF\nGHI", str);
    }

    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
        const page = list_cell.node.page();
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = @intCast(x),
            .y = 1,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}

test "Terminal: scrollUp clears hyperlink" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    try t.scrollUp(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("DEF\nGHI", str);
    }

    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
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

test "Terminal: scrollUp top/bottom scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(1, 1);

    clearDirty(&t);
    try t.scrollUp(1);

    // This is dirty because the cursor moves from this row
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nGHI", str);
    }
}

test "Terminal: scrollUp left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);

    const cursor = t.screens.active.cursor;
    clearDirty(&t);
    try t.scrollUp(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AEF423\nDHI756\nG   89", str);
    }
}

test "Terminal: scrollUp left/right scroll region hyperlink" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("DEF456");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);
    try t.scrollUp(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AEF423\nDHI756\nG   89", str);
    }

    // First row gets some hyperlinks
    {
        for (0..1) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell);
            try testing.expect(id == null);
        }
        for (1..4) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = list_cell.node.page();
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
        for (4..6) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell);
            try testing.expect(id == null);
        }
    }

    // Second row preserves hyperlink where we didn't scroll
    {
        for (0..1) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = list_cell.node.page();
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
        for (1..4) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell);
            try testing.expect(id == null);
        }
        for (4..6) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = list_cell.node.page();
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
    }
}

test "Terminal: scrollUp preserves pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(1, 5);
    try t.print('A');
    t.setCursorPos(2, 5);
    try t.print('B');
    t.setCursorPos(3, 5);
    try t.print('C');
    try t.scrollUp(1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    B\n    C\n\nX", str);
    }
}

test "Terminal: scrollUp full top/bottom region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("top");
    t.setCursorPos(5, 1);
    try t.printString("ABCDE");
    t.setTopAndBottomMargin(2, 5);

    clearDirty(&t);
    try t.scrollUp(4);

    // This is dirty because the cursor moves from this row
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("top", str);
    }
}

test "Terminal: scrollUp full top/bottomleft/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("top");
    t.setCursorPos(5, 1);
    try t.printString("ABCDE");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setTopAndBottomMargin(2, 5);
    t.setLeftAndRightMargin(2, 4);

    clearDirty(&t);
    try t.scrollUp(4);

    // This is dirty because the cursor moves from this row
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    for (1..5) |y| try testing.expect(isDirty(&t, .{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("top\n\n\n\nA   E", str);
    }
}

test "Terminal: scrollUp creates scrollback in primary screen" {
    // When in primary screen with full-width scroll region at top,
    // scrollUp (CSI S) should push lines into scrollback like xterm.
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5, .max_scrollback_bytes = 10 });
    defer t.deinit(alloc);

    // Fill the screen with content
    try t.printString("AAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("BBBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("CCCCC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DDDDD");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("EEEEE");

    clearDirty(&t);

    // Scroll up by 1, which should push "AAAAA" into scrollback
    try t.scrollUp(1);

    // The cursor row (new empty row) should be dirty
    try testing.expect(t.screens.active.cursor.page_row.dirty);

    // The active screen should now show BBBBB through EEEEE plus one blank line
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("BBBBB\nCCCCC\nDDDDD\nEEEEE", str);
    }

    // Now scroll to the top to see scrollback - AAAAA should be there
    t.screens.active.scroll(.{ .top = {} });
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        // Should see AAAAA in scrollback
        try testing.expectEqualStrings("AAAAA\nBBBBB\nCCCCC\nDDDDD\nEEEEE", str);
    }
}

test "Terminal: scrollUp with max_scrollback_bytes zero" {
    // When max_scrollback_bytes is 0, scrollUp should still work but not retain history
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5, .max_scrollback_bytes = 0 });
    defer t.deinit(alloc);

    try t.printString("AAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("BBBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("CCCCC");

    try t.scrollUp(1);

    // Active screen should show scrolled content
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("BBBBB\nCCCCC", str);
    }

    // Scroll to top - should be same as active since no scrollback
    t.screens.active.scroll(.{ .top = {} });
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("BBBBB\nCCCCC", str);
    }
}

test "Terminal: scrollUp with max_scrollback_bytes zero and top margin" {
    // When max_scrollback_bytes is 0 and top margin is set, should use deleteLines path
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5, .max_scrollback_bytes = 0 });
    defer t.deinit(alloc);

    try t.printString("AAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("BBBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("CCCCC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DDDDD");

    // Set top margin (not at row 0)
    t.setTopAndBottomMargin(2, 5);

    try t.scrollUp(1);

    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        // First row preserved, rest scrolled
        try testing.expectEqualStrings("AAAAA\nCCCCC\nDDDDD", str);
    }
}

test "Terminal: scrollUp with max_scrollback_bytes zero and left/right margin" {
    // When max_scrollback_bytes is 0 with left/right margins, uses deleteLines path
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 10, .max_scrollback_bytes = 0 });
    defer t.deinit(alloc);

    try t.printString("AAAAABBBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("CCCCCDDDDD");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("EEEEEFFFFF");

    // Set left/right margins (columns 2-6, 1-indexed = indices 1-5)
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 6);

    try t.scrollUp(1);

    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        // cols 1-5 scroll, col 0 and cols 6+ preserved
        try testing.expectEqualStrings("ACCCCDBBBB\nCEEEEFDDDD\nE     FFFF", str);
    }
}

test "Terminal: scrollDown simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);

    const cursor = t.screens.active.cursor;
    clearDirty(&t);
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);

    for (0..5) |y| try testing.expect(isDirty(&t, .{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

test "Terminal: scrollDown hyperlink moves" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }

    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = @intCast(x),
            .y = 1,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
        const page = list_cell.node.page();
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
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

test "Terminal: scrollDown outside of scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(3, 4);
    t.setCursorPos(2, 2);

    const cursor = t.screens.active.cursor;
    clearDirty(&t);
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);

    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    // This is dirty because the cursor moves from this row
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\n\nGHI", str);
    }
}

test "Terminal: scrollDown left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);

    const cursor = t.screens.active.cursor;
    clearDirty(&t);
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);

    for (0..4) |y| try testing.expect(isDirty(&t, .{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A   23\nDBC156\nGEF489\n HI7", str);
    }
}

test "Terminal: scrollDown left/right scroll region hyperlink" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC123");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);
    t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A   23\nDBC156\nGEF489\n HI7", str);
    }

    // First row preserves hyperlink where we didn't scroll
    {
        for (0..1) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = list_cell.node.page();
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
        for (1..4) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell);
            try testing.expect(id == null);
        }
        for (4..6) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = list_cell.node.page();
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
    }

    // Second row gets some hyperlinks
    {
        for (0..1) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell);
            try testing.expect(id == null);
        }
        for (1..4) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = list_cell.node.page();
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
        for (4..6) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell);
            try testing.expect(id == null);
        }
    }
}

test "Terminal: scrollDown outside of left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(1, 1);

    const cursor = t.screens.active.cursor;
    clearDirty(&t);
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);

    for (0..4) |y| try testing.expect(isDirty(&t, .{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A   23\nDBC156\nGEF489\n HI7", str);
    }
}

test "Terminal: scrollDown preserves pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);

    t.setCursorPos(1, 5);
    try t.print('A');
    t.setCursorPos(2, 5);
    try t.print('B');
    t.setCursorPos(3, 5);
    try t.print('C');
    t.scrollDown(1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n    A\n    B\nX   C", str);
    }
}

test "Terminal: reverseIndex" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.reverseIndex();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    t.carriageReturn();
    try t.linefeed();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nBD\nC", str);
    }
}

test "Terminal: reverseIndex from the top" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    t.carriageReturn();
    try t.linefeed();

    t.setCursorPos(1, 1);
    t.reverseIndex();
    try t.print('D');

    t.carriageReturn();
    try t.linefeed();
    t.setCursorPos(1, 1);
    t.reverseIndex();
    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nD\nA\nB", str);
    }
}

test "Terminal: reverseIndex top of scrolling region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 10 });
    defer t.deinit(alloc);

    // Initial value
    t.setCursorPos(2, 1);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();

    // Set our scroll region
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(2, 1);
    t.reverseIndex();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nX\nA\nB\nC", str);
    }
}

test "Terminal: reverseIndex top of screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setCursorPos(1, 1);
    t.reverseIndex();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nA\nB\nC", str);
    }
}

test "Terminal: reverseIndex not top of screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setCursorPos(2, 1);
    t.reverseIndex();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nB\nC", str);
    }
}

test "Terminal: reverseIndex top/bottom margins" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(2, 1);
    t.reverseIndex();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\nB", str);
    }
}

test "Terminal: reverseIndex outside top/bottom margins" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(1, 1);
    t.reverseIndex();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nB\nC", str);
    }
}

test "Terminal: reverseIndex left/right margins" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.setCursorPos(2, 1);
    try t.printString("DEF");
    t.setCursorPos(3, 1);
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 3);
    t.setCursorPos(1, 2);
    t.reverseIndex();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nDBC\nGEF\n HI", str);
    }
}

test "Terminal: reverseIndex outside left/right margins" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.setCursorPos(2, 1);
    try t.printString("DEF");
    t.setCursorPos(3, 1);
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 3);
    t.setCursorPos(1, 1);
    t.reverseIndex();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: index" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    try t.index();
    try t.print('A');

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }
}

test "Terminal: index from the bottom" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.print('A');
    t.cursorLeft(1); // undo moving right from 'A'

    clearDirty(&t);
    try t.index();
    try t.print('B');

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 4 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\nB", str);
    }
}

test "Terminal: index scrolling with hyperlink" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.print('A');
    t.screens.active.endHyperlink();
    t.cursorLeft(1); // undo moving right from 'A'
    try t.index();
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\nB", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = 3,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = 4,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}

test "Terminal: index outside of scrolling region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    t.setTopAndBottomMargin(2, 5);
    try t.index();
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
}

test "Terminal: index from the bottom outside of scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(5, 1);
    try t.print('A');
    clearDirty(&t);
    try t.index();
    try t.print('B');
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 4 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n\nAB", str);
    }
}

test "Terminal: index no scroll region, top of screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    clearDirty(&t);
    try t.index();
    try t.print('X');

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n X", str);
    }
}

test "Terminal: index bottom of primary screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.print('A');
    clearDirty(&t);
    try t.index();
    try t.print('X');

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 4 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\n X", str);
    }
}

test "Terminal: index bottom of primary screen background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.print('A');
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.index();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA", str);
        for (0..5) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 4,
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

test "Terminal: index inside scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    try t.print('A');
    clearDirty(&t);
    try t.index();
    try t.print('X');

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n X", str);
    }
}

test "Terminal: index bottom of scroll region with hyperlinks" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 2);
    try t.print('A');
    try t.index();
    t.carriageReturn();
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.print('B');
    t.screens.active.endHyperlink();
    try t.index();
    t.carriageReturn();
    try t.print('C');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nC", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = 1,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}

test "Terminal: index bottom of scroll region clear hyperlinks" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5, .max_scrollback_bytes = 0 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(2, 1);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.print('A');
    t.screens.active.endHyperlink();
    try t.index();
    t.carriageReturn();
    try t.print('B');
    try t.index();
    t.carriageReturn();
    try t.print('C');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nB\nC", str);
    }

    for (1..3) |y| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
        const page = list_cell.node.page();
        try testing.expectEqual(0, page.hyperlink_set.count());
    }
}

test "Terminal: index bottom of scroll region with background SGR" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(4, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('A');
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.index();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA\n\nB", str);
    }

    for (0..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 2,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: index bottom of primary screen with scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.setCursorPos(5, 1);
    clearDirty(&t);
    try t.index();
    try t.index();
    try t.index();
    try t.print('X');

    for (0..4) |y| try testing.expect(!isDirty(&t, .{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 4 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nA\n\nX", str);
    }
}

test "Terminal: index outside left/right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    t.scrolling_region.left = 3;
    t.scrolling_region.right = 5;
    t.setCursorPos(3, 3);
    try t.print('A');
    t.setCursorPos(3, 1);
    clearDirty(&t);
    try t.index();
    try t.print('X');

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nX A", str);
    }
}

test "Terminal: index inside left/right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.printString("AAAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("AAAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("AAAAAA");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setTopAndBottomMargin(1, 3);
    t.setLeftAndRightMargin(1, 3);
    t.setCursorPos(3, 1);

    clearDirty(&t);
    try t.index();

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));

    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAAAA\nAAAAAA\n   AAA", str);
    }
}

test "Terminal: index bottom of scroll region creates scrollback" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    try t.printString("1\n2\n3");
    t.setCursorPos(4, 1);
    try t.print('X');
    t.setCursorPos(3, 1);
    try t.index();
    try t.print('Y');

    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2\n3\nY\nX", str);
    }
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1\n2\n3\nY\nX", str);
    }
}

test "Terminal: index bottom of scroll region no scrollback" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5, .max_scrollback_bytes = 0 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(4, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('A');
    clearDirty(&t);
    try t.index();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA\n X\nB", str);
    }
}

test "Terminal: index bottom of scroll region blank line preserves SGR" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    try t.printString("1\n2\n3");
    t.setCursorPos(4, 1);
    try t.print('X');
    t.setCursorPos(3, 1);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.index();

    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2\n3\n\nX", str);
    }
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1\n2\n3\n\nX", str);
    }
    for (0..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 2,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: index bottom of scroll region with top margin and background SGR" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("1\n2\n3\n4\n5");
    t.setTopAndBottomMargin(2, 4);
    t.setCursorPos(4, 1);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.index();

    // The region (rows 2-4) scrolled up, rows outside are unchanged.
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1\n3\n4\n\n5", str);
    }

    // The cursor is on the new blank row.
    try testing.expectEqual(@as(usize, 3), t.screens.active.cursor.y);

    // The new blank row must be filled with our background color.
    for (0..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 3,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: index bottom of alt screen full region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 5 });
    defer t.deinit(alloc);

    try t.switchScreenMode(.@"1049", true);
    try t.printString("A\nB\nC");
    try t.index();
    t.carriageReturn();
    try t.print('D');

    // Content scrolled up and the scrolled-out row is discarded, NOT
    // moved into scrollback (the alt screen has none).
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nC\nD", str);
    }
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nC\nD", str);
    }

    // Primary screen is untouched.
    try t.switchScreenMode(.@"1049", false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: index bottom of alt screen top region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.switchScreenMode(.@"1049", true);
    try t.printString("1\n2\n3\n4\n5");

    // Region at the top of the screen, excluding the last row. On the
    // alt screen this must NOT create scrollback.
    t.setTopAndBottomMargin(1, 4);
    t.setCursorPos(4, 1);
    try t.index();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2\n3\n4\nX\n5", str);
    }
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2\n3\n4\nX\n5", str);
    }
}

test "Terminal: scrollUp top region no scrollback" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5, .max_scrollback_bytes = 0 });
    defer t.deinit(alloc);

    try t.printString("A\nB\nC\nD\nE");
    t.setTopAndBottomMargin(1, 3);
    try t.scrollUp(1);

    // The region scrolled and the scrolled-out row is discarded.
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nC\n\nD\nE", str);
    }
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nC\n\nD\nE", str);
    }
}

test "Terminal: cursorUp below top scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(2, 4);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.cursorUp(5);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n X\nA", str);
    }
}

test "Terminal: cursorUp above top scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(3, 5);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.setCursorPos(2, 1);
    t.cursorUp(10);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\n\nA", str);
    }
}

test "Terminal: cursorLeft reverse wrap before left margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);
    t.setTopAndBottomMargin(3, 0);
    t.cursorLeft(1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nX", str);
    }
}

test "Terminal: cursorLeft extended reverse wrap above top scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);

    t.setTopAndBottomMargin(3, 0);
    t.setCursorPos(2, 1);
    t.cursorLeft(1000);

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
}

test "Terminal: cursorDown above bottom scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    try t.print('A');
    t.cursorDown(10);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n X", str);
    }
}

test "Terminal: cursorDown below bottom scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    try t.print('A');
    t.setCursorPos(4, 1);
    t.cursorDown(10);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\n\nX", str);
    }
}

test "Terminal: cursorRight left of right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.scrolling_region.right = 2;
    t.cursorRight(100);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X", str);
    }
}

test "Terminal: cursorRight right of right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.scrolling_region.right = 2;
    t.setCursorPos(1, 4);
    t.cursorRight(100);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    X", str);
    }
}

test "Terminal: deleteLines simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);

    const node = t.screens.active.cursor.page_pin.node;
    const serial = node.serial;
    clearDirty(&t);
    t.deleteLines(1);
    try testing.expect(!t.screens.active.pages.nodeIsValid(node, serial));

    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nGHI", str);
    }
}

test "Terminal: deleteLines colors with bg color" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);

    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nGHI", str);
    }

    for (0..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 4,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: deleteLines across page boundary marks all shifted rows dirty" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 10, .max_scrollback_bytes = 1024 });
    defer t.deinit(alloc);

    const first_page = t.screens.active.pages.pages.first.?;
    const first_page_nrows = first_page.capacity().rows;

    // Fill up the first page minus 3 rows
    for (0..first_page_nrows - 3) |_| try t.linefeed();

    // Add content that will cross a page boundary
    try t.printString("1AAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("2BBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("3CCCC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("4DDDD");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("5EEEE");

    // Verify we now have a second page
    const second_page = first_page.next.?;
    const first_serial = first_page.serial;
    const second_serial = second_page.serial;

    t.setCursorPos(1, 1);
    clearDirty(&t);
    t.deleteLines(1);
    try testing.expect(!t.screens.active.pages.nodeIsValid(first_page, first_serial));
    try testing.expect(!t.screens.active.pages.nodeIsValid(second_page, second_serial));

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 4 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2BBBB\n3CCCC\n4DDDD\n5EEEE", str);
    }
}

test "Terminal: deleteLines hyperlink-dense row crosses page boundary" {
    // Regression test for the cross-page copy of deleteLines: when the
    // shifted row carries more unique hyperlinks than the destination
    // page's hyperlink capacity, the copy must increase the destination
    // page's capacity and retry rather than corrupting the page list.
    //
    // This is the mirror of the insertLines variant: the dense row
    // starts as the first row of the second page and is pulled up into
    // the first page, which also happens to be the cursor's page so
    // this exercises the cursor accounting of the capacity increase.
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 10, .max_scrollback_bytes = 1024 });
    defer t.deinit(alloc);

    const pages = &t.screens.active.pages;

    // Fill the first page so it is exactly full, then two more rows so
    // the second page holds the last two active rows (y=3 and y=4).
    const first_page_rows = pages.pages.first.?.capacity().rows;
    for (0..first_page_rows + 1) |_| try t.linefeed();
    try testing.expect(pages.pages.first != pages.pages.last);
    try testing.expectEqual(@as(usize, 2), pages.pages.last.?.rows());

    // Marker rows so we can verify the shift afterwards.
    t.setCursorPos(1, 1);
    try t.printString("0");
    t.setCursorPos(2, 1);
    try t.printString("1");
    t.setCursorPos(3, 1);
    try t.printString("2");
    t.setCursorPos(5, 1);
    try t.printString("4");

    // Fill the first row of the second page (active y=3) with unique
    // hyperlinks: more than the first page can hold with its default
    // hyperlink capacity. Writing them grows the second page's
    // capacity as needed; the first page keeps its default capacity.
    t.setCursorPos(4, 1);
    for (0..10) |i| {
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{i});
        try t.screens.active.startHyperlink(uri, null);
        try t.print(@intCast('A' + i));
        t.screens.active.endHyperlink();
    }
    {
        const pin = pages.pin(.{ .active = .{ .y = 3 } }).?;
        try testing.expectEqual(pages.pages.last.?, pin.node);
        try testing.expectEqual(@as(usize, 0), @as(usize, pin.y));
    }
    try testing.expect(pages.pages.first.?.page().hyperlink_set.layout.cap < 10);

    // Delete the top line: every row shifts up by one and the dense
    // row crosses the page boundary into the first page.
    t.setCursorPos(1, 1);
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1\n2\nABCDEFGHIJ\n4", str);
    }

    // The first page's hyperlink capacity had to grow to receive the
    // row, proving the capacity-retry path ran.
    try testing.expect(pages.pages.first.?.page().hyperlink_set.layout.cap >= 10);

    // Every cell of the dense row must still resolve to a real
    // hyperlink entry with the correct URI. A half-applied shift
    // leaves cells whose hyperlink flag is set but that have no map
    // entry, which aborts in clearCells later.
    for (0..10) |x| {
        const list_cell = pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 2,
        } }).?;
        try testing.expect(list_cell.cell.hyperlink);
        const page: *Page = list_cell.node.page();
        const id = page.lookupHyperlink(list_cell.cell).?;
        const link = page.hyperlink_set.get(page.memory, id);
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{x});
        try testing.expectEqualStrings(uri, link.uri.slice(page.memory));
    }

    // All pages must pass integrity checks.
    var node_: ?*PageList.List.Node = pages.pages.first;
    while (node_) |node| : (node_ = node.next) node.page().assertIntegrity();
}

test "Terminal: deleteLines (legacy)" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 80, .rows = 80 });
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');

    t.cursorUp(2);
    t.deleteLines(1);

    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    // We should be
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.y);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nE\nD", str);
    }
}

test "Terminal: deleteLines with scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 80, .rows = 80 });
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(1, 1);

    clearDirty(&t);
    t.deleteLines(1);

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    // We should be
    // try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    // try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.y);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nC\n\nD", str);
    }
}

test "Terminal: deleteLines with scroll region, large count" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 80, .rows = 80 });
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(1, 1);

    clearDirty(&t);
    t.deleteLines(5);

    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 3 } }));

    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    // We should be
    // try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    // try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.y);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\n\n\nD", str);
    }
}

test "Terminal: deleteLines with scroll region, cursor outside of region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 80, .rows = 80 });
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(4, 1);

    clearDirty(&t);
    t.deleteLines(1);

    for (0..4) |y| try testing.expect(!isDirty(&t, .{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nB\nC\nD", str);
    }
}

test "Terminal: deleteLines resets pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.deleteLines(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B", str);
    }
}

test "Terminal: deleteLines resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    try t.print('1');
    t.carriageReturn();
    try t.linefeed();
    for ("ABCDEF") |c| try t.print(c);

    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(1, 1);
    t.deleteLines(1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBC\n\nDEF", str);
    }

    for (0..t.rows) |y| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
}

test "Terminal: deleteLines left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);

    clearDirty(&t);
    t.deleteLines(1);

    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    for (1..3) |y| try testing.expect(isDirty(&t, .{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123\nDHI756\nG   89", str);
    }
}

test "Terminal: deleteLines left/right scroll region from top" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(1, 2);

    clearDirty(&t);
    t.deleteLines(1);

    for (0..3) |y| try testing.expect(isDirty(&t, .{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AEF423\nDHI756\nG   89", str);
    }
}

test "Terminal: deleteLines left/right scroll region high count" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);

    clearDirty(&t);
    t.deleteLines(100);

    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    for (1..3) |y| try testing.expect(isDirty(&t, .{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123\nD   56\nG   89", str);
    }
}

test "Terminal: deleteLines wide character spacer head" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    // +-----+
    // |AAAAA| < Wrapped
    // |BBBB*| < Wrapped     (continued)
    // |WWCCC| < Non-wrapped (continued)
    // +-----+
    // where * represents a spacer head cell
    // and WW is the wide character.
    try t.printString("AAAAABBBB\u{1F600}CCC");

    // Delete the top line
    // +-----+
    // |BBBB | < Non-wrapped
    // |WWCCC| < Non-wrapped
    // |     | < Non-wrapped
    // +-----+
    // This should convert the spacer head to
    // a regular empty cell, and un-set wrap.
    t.setCursorPos(1, 1);
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("BBBB\n\u{1F600}CCC", str);
        try testing.expectEqualStrings("BBBB\n\u{1F600}CCC", unwrapped_str);
    }
}

test "Terminal: deleteLines wide character spacer head left scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    // +-----+
    // |AAAAA| < Wrapped
    // |BBBB*| < Wrapped     (continued)
    // |WWCCC| < Non-wrapped (continued)
    // +-----+
    // where * represents a spacer head cell
    // and WW is the wide character.
    try t.printString("AAAAABBBB\u{1F600}CCC");

    t.scrolling_region.left = 2;

    // Delete the top line
    //    ###  <- scrolling region
    // +-----+
    // |AABB | < Wrapped
    // |BBCCC| < Wrapped     (continued)
    // |WW   | < Non-wrapped (continued)
    // +-----+
    // This should convert the spacer head to
    // a regular empty cell, but due to the
    // left scrolling margin, wrap state should
    // remain.
    t.setCursorPos(1, 3);
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("AABB\nBBCCC\n\u{1F600}", str);
        try testing.expectEqualStrings("AABB BBCCC\u{1F600}", unwrapped_str);
    }
}

test "Terminal: deleteLines wide character spacer head right scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    // +-----+
    // |AAAAA| < Wrapped
    // |BBBB*| < Wrapped     (continued)
    // |WWCCC| < Non-wrapped (continued)
    // +-----+
    // where * represents a spacer head cell
    // and WW is the wide character.
    try t.printString("AAAAABBBB\u{1F600}CCC");

    t.scrolling_region.right = 3;

    // Delete the top line
    //  ####   <- scrolling region
    // +-----+
    // |BBBBA| < Wrapped
    // |WWCC | < Wrapped     (continued)
    // |    C| < Non-wrapped (continued)
    // +-----+
    // This should convert the spacer head to
    // a regular empty cell, but due to the
    // right scrolling margin, wrap state should
    // remain.
    t.setCursorPos(1, 1);
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("BBBBA\n\u{1F600}CC\n    C", str);
        try testing.expectEqualStrings("BBBBA\u{1F600}CC     C", unwrapped_str);
    }
}

test "Terminal: deleteLines wide character spacer head left and right scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    // +-----+
    // |AAAAA| < Wrapped
    // |BBBB*| < Wrapped     (continued)
    // |WWCCC| < Non-wrapped (continued)
    // +-----+
    // where * represents a spacer head cell
    // and WW is the wide character.
    try t.printString("AAAAABBBB\u{1F600}CCC");

    t.scrolling_region.right = 3;
    t.scrolling_region.left = 2;

    // Delete the top line
    //    ##   <- scrolling region
    // +-----+
    // |AABBA| < Wrapped
    // |BBCC*| < Wrapped     (continued)
    // |WW  C| < Non-wrapped (continued)
    // +-----+
    // Because there is both a left scrolling
    // margin > 1 and a right scrolling margin
    // the spacer head should remain, and the
    // wrap state should be untouched.
    t.setCursorPos(1, 3);
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("AABBA\nBBCC\n\u{1F600}  C", str);
        try testing.expectEqualStrings("AABBABBCC\u{1F600}  C", unwrapped_str);
    }
}

test "Terminal: deleteLines wide character spacer head left (< 2) and right scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    // +-----+
    // |AAAAA| < Wrapped
    // |BBBB*| < Wrapped     (continued)
    // |WWCCC| < Non-wrapped (continued)
    // +-----+
    // where * represents a spacer head cell
    // and WW is the wide character.
    try t.printString("AAAAABBBB\u{1F600}CCC");

    t.scrolling_region.right = 3;
    t.scrolling_region.left = 1;

    // Delete the top line
    //   ###   <- scrolling region
    // +-----+
    // |ABBBA| < Wrapped
    // |B CC | < Wrapped     (continued)
    // |    C| < Non-wrapped (continued)
    // +-----+
    // Because the left margin is 1, the wide
    // char is split, and therefore removed,
    // along with the spacer head - however,
    // wrap state should be untouched.
    t.setCursorPos(1, 2);
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("ABBBA\nB CC\n    C", str);
        try testing.expectEqualStrings("ABBBAB CC     C", unwrapped_str);
    }
}

test "Terminal: deleteLines wide characters split by left/right scroll region boundaries" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    // Initial value
    // +-----+
    // |AAAAA|
    // |WWBWW|
    // +-----+
    // where WW represents a wide character
    try t.printString("AAAAA\n\u{1F600}B\u{1F600}");

    t.scrolling_region.right = 3;
    t.scrolling_region.left = 1;

    // Delete the top line
    //   ###   <- scrolling region
    // +-----+
    // |A B A|
    // |     |
    // +-----+
    // The two wide chars, because they're
    // split by the edge of the scrolling
    // region, get removed.
    t.setCursorPos(1, 2);
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A B A", str);
    }
}

test "Terminal: deleteLines zero" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    // This should do nothing
    t.setCursorPos(1, 1);
    t.deleteLines(0);
}

test "Terminal: decaln reset margins" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    t.modes.set(.origin, true);
    t.setTopAndBottomMargin(2, 3);
    try t.decaln();
    t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nEEE\nEEE", str);
    }
}

test "Terminal: insertBlanks no scroll region, fits" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);

    clearDirty(&t);
    t.insertBlanks(2);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }
}

test "Terminal: insertBlanks inside left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.setCursorPos(1, 3);
    for ("ABC") |c| try t.print(c);
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

test "Terminal: insertBlanks outside left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);

    t.setCursorPos(1, 4);
    for ("ABC") |c| try t.print(c);
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    try testing.expect(t.screens.active.cursor.pending_wrap);
    clearDirty(&t);
    t.insertBlanks(2);
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("   ABX", str);
    }
}

test "Terminal: insertBlanks left/right scroll region large count" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    t.modes.set(.origin, true);
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 1);
    clearDirty(&t);
    t.insertBlanks(140);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X", str);
    }
}

test "Terminal: insertBlanks wide char straddling right margin" {
    // Crash found by AFL++ fuzzer.
    //
    // When a wide character straddles the right scroll margin (head at the
    // margin, spacer_tail just beyond it), insertBlanks shifts the wide head
    // away via swapCells but leaves the orphaned spacer_tail in place,
    // causing a page integrity violation.
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Fill row: A B C D 橋 _ _ _ _ _
    // Positions: 0 1 2 3 4W 5T 6 7 8 9
    t.setCursorPos(1, 1);
    for ("ABCD") |c| try t.print(c);
    try t.print('橋'); // wide char: head at 4, spacer_tail at 5

    // Set right margin so the wide head is AT the boundary and the
    // spacer_tail is just outside it.
    t.scrolling_region.right = 4;

    // Position cursor at x=2 (1-indexed col 3) and insert one blank.
    // This triggers the swap loop which displaces the wide head at
    // position 4 without clearing the spacer_tail at position 5.
    t.setCursorPos(1, 3);
    t.insertBlanks(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB CD", str);
    }
}

test "Terminal: insertBlanks wide char spacer_tail orphaned beyond right margin" {
    // Regression test for AFL++ crash.
    //
    // When insertBlanks clears the entire region from cursor to the right
    // margin (scroll_amount == 0), a wide character whose head is AT the
    // right margin gets cleared but its spacer_tail just beyond the margin
    // is left behind, causing a page integrity violation:
    //   "spacer tail not following wide"
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Fill cols 0–9 with wide chars: 中中中中中
    // Positions: 0W 1T 2W 3T 4W 5T 6W 7T 8W 9T
    for (0..5) |_| try t.print(0x4E2D);

    // Set left/right margins so that the last wide char (cols 8–9)
    // straddles the boundary: head at col 8 (inside), tail at col 9 (outside).
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(1, 9); // 1-indexed: left=0, right=8

    // Cursor is now at (0, 0) after DECSLRM.  Print a narrow char to
    // advance cursor to col 1.
    try t.print('a');

    // ICH 8: insert 8 blanks at cursor x=1.
    // rem = right(8) - x(1) + 1 = 8, adjusted_count = 8, scroll_amount = 0.
    // The code clears cols 1–8 without noticing the spacer_tail at col 9.
    t.insertBlanks(8);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("a", str);
    }
}

test "Terminal: deleteChars outside scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    try testing.expect(t.screens.active.cursor.pending_wrap);
    clearDirty(&t);
    t.deleteChars(2);
    try testing.expect(!isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.screens.active.cursor.pending_wrap);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123", str);
    }
}

test "Terminal: deleteChars inside scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.setCursorPos(1, 4);

    clearDirty(&t);
    t.deleteChars(1);
    try testing.expect(isDirty(&t, .{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC2 3", str);
    }
}

test "Terminal: deleteChars wide char across right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 8 });
    defer t.deinit(alloc);

    // scroll region
    //    VVVVVV
    //  +-######-+
    //  |.abcdeWW|
    //  : ^      : (^ = cursor)
    //  +--------+
    //
    // DCH 1

    try t.printString("123456橋");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 7);

    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123456橋", str);
    }

    t.setCursorPos(1, 2);
    t.deleteChars(1);
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();

    // NOTE: This behavior is slightly inconsistent with xterm. xterm
    // _visually_ splits the wide character (half the wide character shows
    // up in col 6 and half in col 8). In all other wide char split scenarios,
    // xterm clears the cell. Therefore, we've chosen to clear the cell here.
    // Given we have space, we also could actually preserve it, but I haven't
    // yet found a terminal that behaves that way. We should be open to
    // revisiting this behavior but for now we're going with the simpler
    // impl.
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("13456", str);
    }
}

test "Terminal: eraseDisplay scroll complete" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    t.eraseDisplay(.scroll_complete, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: index in prompt mode marks new row as prompt continuation" {
    // This tests the Fish shell workaround: when in prompt mode and we get
    // a newline, assume the new row is a prompt continuation (since Fish
    // doesn't emit OSC133 k=s markers for continuation lines).
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Start a prompt
    try t.semanticPrompt(.init(.prompt_start));
    for ("hello") |c| try t.print(c);

    // Verify first row is marked as prompt
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).?;
        try testing.expectEqual(.prompt, list_cell.row.semantic_prompt);
    }

    // Now do a linefeed while still in prompt mode
    t.carriageReturn();
    try t.linefeed();

    // The new row should automatically be marked as prompt continuation
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }

    // The cursor semantic content should still be prompt
    try testing.expectEqual(.prompt, t.screens.active.cursor.semantic_content);
}

test "Terminal: index in input mode does not mark new row as prompt" {
    // Input mode should NOT trigger prompt continuation on newline
    // (only prompt mode does, not input mode)
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Start a prompt then switch to input
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    for ("echo \\") |c| try t.print(c);

    // Linefeed while in input mode
    t.carriageReturn();
    try t.linefeed();

    // The new row should be marked as prompt continuation
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }

    // Our cursor should still be in input
    try testing.expectEqual(.input, t.screens.active.cursor.semantic_content);
}

test "Terminal: index in output mode does not mark new row as prompt" {
    // Output mode should NOT trigger prompt continuation
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Complete prompt cycle: prompt -> input -> output
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    for ("ls") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_input_start_output));

    // Linefeed while in output mode
    t.carriageReturn();
    try t.linefeed();

    // The new row should NOT be marked as a prompt
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.none, list_cell.row.semantic_prompt);
    }
}

// https://github.com/mitchellh/ghostty/issues/723
// This was found via fuzzing so its highly specific.
test "Terminal: resize with left and right margin set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    const cols = 70;
    const rows = 23;
    var t = try init(io_impl, alloc, .{ .cols = cols, .rows = rows });
    defer t.deinit(alloc);

    t.modes.set(.enable_left_and_right_margin, true);
    try t.print('0');
    t.modes.set(.enable_mode_3, true);
    try t.resize(alloc, .{ .cols = cols, .rows = rows });
    t.setLeftAndRightMargin(2, 0);
    try t.printRepeat(1850);
    _ = t.modes.restore(.enable_mode_3);
    try t.resize(alloc, .{ .cols = cols, .rows = rows });
}

test "Terminal: resize without scrollback pull" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    t.flags.resize_pull_scrollback = false;

    // This is configuration so it should survive a reset.
    t.fullReset();
    try testing.expect(!t.flags.resize_pull_scrollback);

    try t.printString("1\n2\n3\n4\n5");
    try t.resize(alloc, .{ .cols = 5, .rows = 5 });
    try testing.expectEqual(@as(size.CellCountInt, 2), t.screens.active.cursor.y);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("3\n4\n5", str);
    }
}

test "Terminal: DECCOLM resets scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.enable_left_and_right_margin, true);
    t.setTopAndBottomMargin(2, 3);
    t.setLeftAndRightMargin(3, 5);

    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");

    try testing.expect(t.modes.get(.enable_left_and_right_margin));
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, 4), t.scrolling_region.bottom);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.left);
    try testing.expectEqual(@as(usize, 79), t.scrolling_region.right);
}

// Reproduces a crash found by AFL++ fuzzer (afl-out/stream/default/crashes/
// id:000007,sig:06,src:004522). The crash is a page integrity violation
// "spacer tail not following wide" triggered during scrollUp -> deleteLines
// -> clearCells. When deleteLines count >= scroll region height, all rows
// are cleared (no shifting), so rowWillBeShifted is never called and wide
// characters straddling the right margin boundary leave orphaned spacer_tails.
test "Terminal: deleteLines wide char at right margin with full clear" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    // Place a wide character at col 39 (1-indexed) on several rows.
    // The wide cell lands at col 38 (0-indexed) with spacer_tail at col 39.
    t.setCursorPos(10, 39);
    try t.print(0x4E2D); // '中'

    // Set left/right scroll margins so scrolling_region.right = 38.
    // clearCells will clear cells[4..39], which includes the wide cell
    // at col 38 but NOT the spacer_tail at col 39.
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(5, 39);

    // scrollUp with count >= region height causes deleteLines to clear
    // ALL rows without any shifting, so rowWillBeShifted is never called
    // and the orphaned spacer_tail at col 39 triggers a page integrity
    // violation in clearCells.
    try t.scrollUp(t.rows);
}

test "Terminal: scroll region linefeed recycled row has default metadata" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);

    // A soft-wrapped line across rows 0-2 so that row 1 has both wrap
    // flags set. Mark row 1 as a prompt as well (OSC 133 A would).
    for (0..12) |_| try t.print('A');
    t.screens.active.pages.getCell(
        .{ .active = .{ .y = 1 } },
    ).?.row.semantic_prompt = .prompt;

    // DECSTBM rows 2-4, cursor to the region bottom, and linefeed:
    // row 1 is discarded and its Row storage recycled as the new
    // blank region-bottom row.
    t.setTopAndBottomMargin(2, 4);
    t.setCursorPos(4, 1);
    try t.linefeed();

    {
        const rac = t.screens.active.pages.getCell(.{ .active = .{ .y = 3 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}

test "Terminal: alt screen scroll up recycled row has default metadata" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    try t.switchScreenMode(.@"1049", true);

    // A soft-wrapped line across rows 0-1 and a prompt mark on row 0.
    for (0..7) |_| try t.print('A');
    t.screens.active.pages.getCell(
        .{ .active = .{} },
    ).?.row.semantic_prompt = .prompt;

    // Scroll up: with no scrollback, row 0 is discarded and its Row
    // storage recycled as the new blank bottom row.
    try t.scrollUp(1);

    {
        const rac = t.screens.active.pages.getCell(.{ .active = .{ .y = 2 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}

test "Terminal: insertLines count over region blanks row metadata" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);

    // A soft-wrapped line across rows 0-2 so that row 1 has both wrap
    // flags set, plus a prompt mark on row 1.
    for (0..12) |_| try t.print('A');
    t.screens.active.pages.getCell(
        .{ .active = .{ .y = 1 } },
    ).?.row.semantic_prompt = .prompt;

    // Insert more lines than remain in the region: every row from the
    // cursor to the region bottom is blanked in place, with no shifts.
    t.setCursorPos(2, 1);
    t.insertLines(10);

    for (1..5) |y| {
        const rac = t.screens.active.pages.getCell(
            .{ .active = .{ .y = @intCast(y) } },
        ).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}

test "Terminal: deleteLines count over region blanks row metadata" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);

    for (0..12) |_| try t.print('A');
    t.screens.active.pages.getCell(
        .{ .active = .{ .y = 1 } },
    ).?.row.semantic_prompt = .prompt;

    t.setCursorPos(2, 1);
    t.deleteLines(10);

    for (1..5) |y| {
        const rac = t.screens.active.pages.getCell(
            .{ .active = .{ .y = @intCast(y) } },
        ).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}

test "Terminal: deleteLines blank row does not retain semantic prompt" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    // Mark row 0 as a prompt row, then delete it. The blank row that
    // appears at the region bottom reuses the deleted row's storage
    // and must not read as a prompt (e.g. for prompt navigation).
    try t.print('$');
    t.screens.active.pages.getCell(
        .{ .active = .{} },
    ).?.row.semantic_prompt = .prompt;

    t.setCursorPos(1, 1);
    t.deleteLines(1);

    {
        const rac = t.screens.active.pages.getCell(.{ .active = .{ .y = 2 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}

test "scroll journal records exact terminal regions once" {
    const alloc = testing.allocator;
    var t = try init(testing.io, alloc, .{ .cols = 20, .rows = 10 });
    defer t.deinit(alloc);
    t.scrolling_region = .{ .left = 0, .top = 1, .right = 19, .bottom = 8 };
    t.screens.active.cursorAbsolute(0, 3);
    t.deleteLines(2);
    var event = t.scroll_state.event(0).?;
    try testing.expectEqual(@as(u16, 3), event.rect.top);
    try testing.expectEqual(@as(u16, 9), event.rect.bottom);
    try testing.expectEqual(@as(i32, -2), event.rows);
    t.insertLines(1);
    try testing.expectEqual(@as(i32, 1), t.scroll_state.event(1).?.rows);
    try t.scrollUp(1);
    try testing.expectEqual(@as(u64, 3), t.scroll_state.serial);
    event = t.scroll_state.event(2).?;
    try testing.expectEqual(@as(u16, 1), event.rect.top);
    t.screens.active.cursorAbsolute(0, 8);
    try t.index();
    try testing.expectEqual(@as(u64, 4), t.scroll_state.serial);
    try testing.expectEqual(@as(i32, -1), t.scroll_state.event(3).?.rows);
}
