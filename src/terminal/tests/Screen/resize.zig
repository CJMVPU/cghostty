//! Screen resize regression tests.
const cursorDownOrScroll = support.cursorDownOrScroll;
const support = @import("support.zig");
const Screen = support.Screen;
const std = support.std;
const size = support.size;
const style = support.style;
const Cell = support.Cell;
const init = support.init;
const resize_tw = support.resize_tw;

test "Screen write regrows compacted page capacity" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();

    // Compact the active page so every managed capacity dimension is
    // zero, then reload the cursor since its cached row/cell pointers
    // point into the replaced page.
    {
        const node = (try s.pages.compact(s.cursor.page_pin.node)).?;
        try testing.expectEqual(0, node.capacity().styles);
        try testing.expectEqual(0, node.capacity().grapheme_bytes);
        try testing.expectEqual(0, node.capacity().string_bytes);
        try testing.expectEqual(0, node.capacity().hyperlink_bytes);
        s.cursorReload();
    }

    // Styled write: exercises the manualStyleUpdate single-retry
    // path. Prior to increaseCapacity handling zero dimensions, the
    // retry would fail and the style would be dropped.
    try s.setAttribute(.{ .bold = {} });
    try s.testWriteString("A");

    // Grapheme write: exercises the appendGrapheme single-retry path.
    // We can't use testWriteString here because it appends graphemes
    // directly on the page without the capacity retry.
    try s.testWriteString("a");
    try s.appendGrapheme(s.cursorCellLeft(1), 0x0301);

    // Hyperlink: exercises the startHyperlink retry loop, which used
    // to loop forever when capacity growth from zero didn't grow.
    try s.startHyperlink("https://example.com/", null);
    try s.testWriteString("B");
    s.endHyperlink();

    // Verify the content landed on the page.
    const page = s.cursor.page_pin.node.page();
    try testing.expect(page.styles.count() >= 1);
    try testing.expect(page.hyperlink_set.count() >= 1);
    try testing.expect(page.graphemeCount() >= 1);
}

test "Screen: cursorAbsolute to page with insufficient capacity" {
    // This test checks for a very specific edge case
    // which previously resulted in memory corruption.
    //
    // The conditions for this edge case are as such:
    // - The cursor has an associated style or other managed memory.
    // - The cursor moves to a different page.
    // - The new page is at capacity and must have its capacity adjusted.

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();

    // Scroll down enough to go to another page
    const start_page = s.pages.pages.last.?.page();
    const rem = start_page.capacity.rows;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try cursorDownOrScroll(&s);
    start_page.pauseIntegrityChecks(false);

    const new_page = s.cursor.page_pin.node.page();

    // We need our page to change for this test to make sense. If this
    // assertion fails then the bug is in the test: we should be scrolling
    // above enough for a new page to show up.
    try testing.expect(start_page != new_page);

    // Add styles to the start page until it reaches capacity.
    {
        // Pause integrity checks because they're slow and
        // we're not testing this, this is just setup.
        start_page.pauseIntegrityChecks(true);
        defer start_page.pauseIntegrityChecks(false);
        defer start_page.assertIntegrity();

        var n: u24 = 1;
        while (start_page.styles.add(
            start_page.memory,
            .{ .bg_color = .{ .rgb = @bitCast(n) } },
        )) |_| n += 1 else |_| {}
    }

    // Set a style on the cursor.
    try s.setAttribute(.{ .bold = {} });
    {
        const styleval = new_page.styles.get(
            new_page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }

    // Go back up into the start page and we should still have that style.
    s.cursorAbsolute(1, 1);
    {
        const cur_page = s.cursor.page_pin.node.page();
        // The page we're on now should NOT equal start_page, since its
        // capacity should have been adjusted, which invalidates our ptr.
        try testing.expect(start_page != cur_page);
        // To make sure we DID change pages we check we're not on new_page.
        try testing.expect(new_page != cur_page);

        const styleval = cur_page.styles.get(
            cur_page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }

    s.cursor.page_pin.node.page().assertIntegrity();
    new_page.assertIntegrity();
}

test "Screen: clone" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);

    // Clone
    var s2 = try s.clone(io, alloc, .{ .active = .{} }, null);
    defer s2.deinit();
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
    try testing.expectEqual(@as(usize, 5), s2.cursor.x);
    try testing.expectEqual(@as(usize, 1), s2.cursor.y);

    // Write to s1, should not be in s2
    try s.testWriteString("\n34567");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n34567", contents);
    }
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
    try testing.expectEqual(@as(usize, 5), s2.cursor.x);
    try testing.expectEqual(@as(usize, 1), s2.cursor.y);
}

test "Screen: clone partial" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);

    // Clone
    var s2 = try s.clone(io, alloc, .{ .active = .{ .y = 1 } }, null);
    defer s2.deinit();
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH", contents);
    }

    // Cursor is shifted since we cloned partial
    try testing.expectEqual(@as(usize, 5), s2.cursor.x);
    try testing.expectEqual(@as(usize, 0), s2.cursor.y);
}

test "Screen: clone partial cursor out of bounds" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);

    // Clone
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = 0 } },
    );
    defer s2.deinit();
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }

    // Cursor is shifted since we cloned partial
    try testing.expectEqual(@as(usize, 0), s2.cursor.x);
    try testing.expectEqual(@as(usize, 0), s2.cursor.y);
}

test "Screen: clone basic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    {
        var s2 = try s.clone(
            io,
            alloc,
            .{ .active = .{ .y = 1 } },
            .{ .active = .{ .y = 1 } },
        );
        defer s2.deinit();

        // Test our contents rotated
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH", contents);
    }

    {
        var s2 = try s.clone(
            io,
            alloc,
            .{ .active = .{ .y = 1 } },
            .{ .active = .{ .y = 2 } },
        );
        defer s2.deinit();

        // Test our contents rotated
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: clone empty viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();

    {
        var s2 = try s.clone(
            io,
            alloc,
            .{ .viewport = .{ .y = 0 } },
            .{ .viewport = .{ .y = 0 } },
        );
        defer s2.deinit();

        // Test our contents rotated
        const contents = try s2.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: clone one line viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABC");

    {
        var s2 = try s.clone(
            io,
            alloc,
            .{ .viewport = .{ .y = 0 } },
            .{ .viewport = .{ .y = 0 } },
        );
        defer s2.deinit();

        // Test our contents
        const contents = try s2.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABC", contents);
    }
}

test "Screen: clone empty active" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();

    {
        var s2 = try s.clone(
            io,
            alloc,
            .{ .active = .{ .y = 0 } },
            .{ .active = .{ .y = 0 } },
        );
        defer s2.deinit();

        // Test our contents rotated
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: clone one line active with extra space" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABC");

    {
        var s2 = try s.clone(
            io,
            alloc,
            .{ .active = .{ .y = 0 } },
            null,
        );
        defer s2.deinit();

        // Test our contents rotated
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABC", contents);
    }
}

test "Screen: resize (no reflow) more rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Resize
    try s.resize(.{ .cols = 10, .rows = 10, .reflow = false });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try testing.expectEqual(5, s.cursor.x);
    try testing.expectEqual(2, s.cursor.y);
    try s.resize(.{ .cols = 10, .rows = 2, .reflow = false });

    // Since we shrunk, we should adjust our cursor
    try testing.expectEqual(5, s.cursor.x);
    try testing.expectEqual(1, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: resize (no reflow) less rows trims blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);

    // Write only a background color into the remaining rows
    for (1..s.pages.rows) |y| {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        list_cell.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }

    const cursor = s.cursor;
    try s.resize(.{ .cols = 6, .rows = 2, .reflow = false });

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}

test "Screen: resize (no reflow) more rows trims blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);

    // Write only a background color into the remaining rows
    for (1..s.pages.rows) |y| {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        list_cell.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }

    const cursor = s.cursor;
    try s.resize(.{ .cols = 10, .rows = 7, .reflow = false });

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}

test "Screen: resize (no reflow) more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 20, .rows = 3, .reflow = false });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 4, .rows = 3, .reflow = false });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABC\n2EFG\n3IJK";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize (no reflow) more rows with scrollback cursor end" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 7, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 7, .rows = 10, .reflow = false });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) more rows no scrollback pull" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 7, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);

    // Cursor is at the bottom so this would normally pull scrollback.
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
    try s.resize(.{
        .cols = 7,
        .rows = 10,
        .reflow = false,
        .pull_scrollback = false,
    });
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL\n4ABCD\n5EFGH", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more cols no scrollback pull" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    try s.testWriteString("1AAAA\n2BBBB\n3CCCCDD\n4E");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3CCCC\nDD\n4E", contents);
    }

    // The wrapped line in the active area unwraps, freeing up a row. This
    // would normally pull "2BBBB" back but we should get a blank row at
    // the bottom instead.
    try s.resize(.{ .cols = 10, .rows = 3, .pull_scrollback = false });
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3CCCCDD\n4E", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1AAAA\n2BBBB\n3CCCCDD\n4E", contents);
    }
}

test "Screen: resize more cols no scrollback pull wrap straddles scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    try s.testWriteString("1AAAA\n2BBBBXX\n3C\n4D");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("XX\n3C\n4D", contents);
    }

    // The line isn't fully in scrollback so it is allowed to unwrap
    // back into view, but nothing above it is.
    try s.resize(.{ .cols = 10, .rows = 3, .pull_scrollback = false });
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2BBBBXX\n3C\n4D", contents);
    }
}

test "Screen: resize more cols and rows no scrollback pull" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    try s.testWriteString("1AAAA\n2BBBB\n3CCCCDD\n4E");

    try s.resize(.{ .cols = 10, .rows = 5, .pull_scrollback = false });
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3CCCCDD\n4E", contents);
    }
}

test "Screen: resize less cols no scrollback pull" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    try s.testWriteString("0Z\n1AAAA\n2BBBBXX\n3C");

    // Wrapping needs more rows than we have so the top of the active
    // area still scrolls off as usual.
    try s.resize(.{ .cols = 5, .rows = 3, .pull_scrollback = false });
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2BBBB\nXX\n3C", contents);
    }
}

test "Screen: resize (no reflow) less rows with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 7, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 7, .rows = 2, .reflow = false });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

// https://github.com/mitchellh/ghostty/issues/1030
test "Screen: resize (no reflow) less rows with empty trailing" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1\n2\n3\n4\n5\n6\n7\n8";
    try s.testWriteString(str);
    try s.scrollClear();
    s.cursorAbsolute(0, 0);
    try s.testWriteString("A\nB");

    const cursor = s.cursor;
    try s.resize(.{ .cols = 5, .rows = 2, .reflow = false });
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("A\nB", contents);
    }
}

test "Screen: resize (no reflow) more rows with soft wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 2, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    const str = "1A2B\n3C4E\n5F6G";
    try s.testWriteString(str);

    // Every second row should be wrapped
    for (0..6) |y| {
        const list_cell = s.pages.getCell(.{ .screen = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        const row = list_cell.row;
        const wrapped = (y % 2 == 0);
        try testing.expectEqual(wrapped, row.wrap);
    }

    // Resize
    try s.resize(.{ .cols = 2, .rows = 10, .reflow = false });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1A\n2B\n3C\n4E\n5F\n6G";
        try testing.expectEqualStrings(expected, contents);
    }

    // Every second row should be wrapped
    for (0..6) |y| {
        const list_cell = s.pages.getCell(.{ .screen = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        const row = list_cell.row;
        const wrapped = (y % 2 == 0);
        try testing.expectEqual(wrapped, row.wrap);
    }
}

test "Screen: resize more rows no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(.{ .cols = 5, .rows = 10 });

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more rows with empty scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(.{ .cols = 5, .rows = 10 });

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more rows with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Set our cursor to be on the "4"
    s.cursorAbsolute(0, 1);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '4'), list_cell.cell.content.codepoint.data);
    }

    // Resize
    try s.resize(.{ .cols = 5, .rows = 10 });

    // Cursor should still be on the "4"
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '4'), list_cell.cell.content.codepoint.data);
    }

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize more cols no reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    const cursor = s.cursor;
    try s.resize(.{ .cols = 10, .rows = 3 });

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

// https://github.com/mitchellh/ghostty/issues/272#issuecomment-1676038963
test "Screen: resize more cols perfect split" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 10, .rows = 3 });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD2EFGH\n3IJKL", contents);
    }
}

// https://github.com/mitchellh/ghostty/issues/1159
test "Screen: resize (no reflow) more cols with scrollback scrolled up" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1\n2\n3\n4\n5\n6\n7\n8";
    try s.testWriteString(str);

    // Cursor at bottom
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);

    s.scroll(.{ .delta_row = -4 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2\n3\n4", contents);
    }

    try s.resize(.{ .cols = 8, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Cursor remains at bottom
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
}

// https://github.com/mitchellh/ghostty/issues/1159
test "Screen: resize (no reflow) less cols with scrollback scrolled up" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1\n2\n3\n4\n5\n6\n7\n8";
    try s.testWriteString(str);

    // Cursor at bottom
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);

    s.scroll(.{ .delta_row = -4 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2\n3\n4", contents);
    }

    try s.resize(.{ .cols = 4, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("6\n7\n8", contents);
    }

    // Cursor remains at bottom
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);

    // Old implementation doesn't do this but it makes sense to me:
    // {
    //     const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
    //     defer alloc.free(contents);
    //     try testing.expectEqualStrings("2\n3\n4", contents);
    // }
}

test "Screen: resize more cols no reflow preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Set one of the rows to be a prompt
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("1ABCD\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("2EFGH");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("\n3IJKL");

    try s.resize(.{ .cols = 10, .rows = 3, .reflow = false });

    const expected = "1ABCD\n2EFGH\n3IJKL";
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(expected, contents);
    }

    // Our one row should still be a semantic prompt, the others should not.
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.row.semantic_prompt == .none);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        try testing.expect(list_cell.row.semantic_prompt == .prompt);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 2 } }).?;
        try testing.expect(list_cell.row.semantic_prompt == .none);
    }
}

test "Screen: resize more cols with reflow that fits full width" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Verify we soft wrapped
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursorAbsolute(0, 1);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '2'), list_cell.cell.content.codepoint.data);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(.{ .cols = 10, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

test "Screen: resize more cols with reflow that ends in newline" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 6, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Verify we soft wrapped
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD2\nEFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Let's put our cursor on the last row
    s.cursorAbsolute(0, 2);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '3'), list_cell.cell.content.codepoint.data);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(.{ .cols = 10, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Our cursor should still be on the 3
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '3'), list_cell.cell.content.codepoint.data);
    }
}

test "Screen: resize more cols with reflow that forces more wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursorAbsolute(0, 1);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '2'), list_cell.cell.content.codepoint.data);
    }

    // Verify we soft wrapped
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(.{ .cols = 7, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD2E\nFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(size.CellCountInt, 5), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.y);
}

test "Screen: resize more cols with reflow that unwraps multiple times" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursorAbsolute(0, 2);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '3'), list_cell.cell.content.codepoint.data);
    }

    // Verify we soft wrapped
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(.{ .cols = 15, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD2EFGH3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(size.CellCountInt, 10), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.y);
}

test "Screen: resize more cols with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // // Set our cursor to be on the "5"
    s.cursorAbsolute(0, 2);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '5'), list_cell.cell.content.codepoint.data);
    }

    // Resize
    try s.resize(.{ .cols = 10, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4ABCD5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should still be on the "5"
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '5'), list_cell.cell.content.codepoint.data);
    }
}

test "Screen: resize more cols bounded scrollback keeps viewport valid" {
    // Regression test for issue #12298.
    //
    // This needs to live at the Screen layer rather than PageList because the
    // bad state only appears once Screen forwards the active cursor into the
    // resize path. A direct PageList resize repro does not hit the same bug.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{
        .cols = 2,
        .rows = 10,
        .max_scrollback_bytes = 10_000,
    });
    defer s.deinit();

    // Build 30 rows of scrollback on top of our 10-row viewport so we have a
    // 40-row screen with history above the active area.
    for (0..30) |_| _ = try s.pages.grow();
    s.cursorReload();
    try testing.expectEqual(@as(usize, 40), s.pages.scrollbar().total);

    // Fill the entire screen with two-row wrapped runs:
    // - even rows mark the end of a wrapped line
    // - odd rows mark the continuation
    //
    // With 2 columns, each logical line occupies two rows. When we grow to 4
    // columns with reflow enabled, those pairs unwrap back into single rows.
    // That cuts the total row count down and is what stresses the viewport pin.
    var it = s.pages.pageIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |chunk| {
        const page = chunk.node.page();
        for (chunk.start..chunk.end) |y| {
            const rac = page.getRowAndCell(0, y);
            if (y % 2 == 0) {
                rac.row.wrap = true;
            } else {
                rac.row.wrap_continuation = true;
            }

            for (0..s.pages.cols) |x| {
                page.getRowAndCell(x, y).cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = @bitCast(@as(u24, 'A')) },
                };
            }
        }
    }

    // Pin the viewport to a history row just above the active area.
    //
    // Before resize:
    // - total rows = 40
    // - active area starts at row 30
    // - viewport is pinned at row 28
    //
    // After unwrap during resize:
    // - total rows shrinks to 20
    // - the old row 28 remaps into what is now the active area
    //
    // The bug was that resize/grow would temporarily keep the viewport as a
    // history pin even after reflow had moved it into the active area, leaving
    // fewer than `rows` visible rows beneath the pin and tripping integrity
    // checks.
    s.pages.scroll(.{ .pin = s.pages.pin(.{ .screen = .{ .y = 28 } }).? });
    try testing.expect(s.pages.viewport == .pin);
    try testing.expect(s.pages.getBottomRight(.viewport) != null);

    // Growing columns triggers reflow, which unwraps the synthetic wrapped
    // rows above. This used to panic during the resize path.
    try s.resize(.{ .cols = 4, .rows = s.pages.rows, .reflow = true });

    // After the fix, the viewport is normalized back to the active area as
    // soon as the pinned row lands there, so viewport queries remain valid.
    try testing.expectEqual(@as(usize, 4), s.pages.cols);
    try testing.expect(s.pages.scrollbar().total < 40);
    try testing.expect(s.pages.viewport == .active);
    try testing.expect(s.pages.getBottomRight(.viewport) != null);
}

test "Screen: resize more cols with reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 2, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1ABC\n2DEF\n3ABC\n4DEF";
    try s.testWriteString(str);

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursorAbsolute(0, 2);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'E'), list_cell.cell.content.codepoint.data);
    }

    // Verify we soft wrapped
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "BC\n4D\nEF";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(.{ .cols = 7, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1ABC\n2DEF\n3ABC\n4DEF";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
}

test "Screen: resize errors preserve state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    for (std.meta.tags(resize_tw.FailPoint)) |tag| {
        const tw = resize_tw;
        defer tw.end(.reset) catch unreachable;

        var s = try init(io, alloc, .{
            .cols = 10,
            .rows = 3,
            .max_scrollback_bytes = 0,
        });
        defer s.deinit();

        s.cursorSetSemanticContent(.{ .prompt = .initial });
        try s.testWriteString("> ");
        s.cursorSetSemanticContent(.{ .input = .clear_explicit });
        try s.testWriteString("echo");
        try s.setAttribute(.{ .bold = {} });
        try s.startHyperlink("https://example.com", "resize");
        s.saved_cursor = .{
            .x = 1,
            .y = 0,
            .style = s.cursor.style,
            .protected = s.cursor.protected,
            .pending_wrap = s.cursor.pending_wrap,
            .origin = false,
            .charset = s.charset,
        };

        {
            s.kitty_images.dirty = false;
        }

        // Keep a shallow copy for all non-page state and a byte-for-byte
        // copy of the sole page so reference counts and prompt contents are
        // covered as well.
        try testing.expectEqual(s.pages.pages.first, s.pages.pages.last);
        const before = s;
        const before_viewport_pin = s.pages.viewport_pin.*;
        const before_tracked_pins = s.pages.countTrackedPins();
        const before_page = try alloc.dupe(
            u8,
            s.pages.pages.first.?.page().memory,
        );
        defer alloc.free(before_page);

        tw.errorAlways(tag, error.OutOfMemory);
        try testing.expectError(error.OutOfMemory, s.resize(.{
            .cols = 20,
            .rows = 4,
            .prompt_redraw = .true,
        }));

        try testing.expect(std.meta.eql(before.cursor, s.cursor));
        try testing.expect(std.meta.eql(before.saved_cursor, s.saved_cursor));
        try testing.expect(std.meta.eql(before.selection, s.selection));
        try testing.expect(std.meta.eql(before.charset, s.charset));
        try testing.expectEqual(before.protected_mode, s.protected_mode);
        try testing.expect(std.meta.eql(before.kitty_keyboard, s.kitty_keyboard));
        try testing.expect(std.meta.eql(before.semantic_prompt, s.semantic_prompt));
        try testing.expectEqual(before.dirty, s.dirty);
        try testing.expectEqual(before.pages.pages.first, s.pages.pages.first);
        try testing.expectEqual(before.pages.pages.last, s.pages.pages.last);
        try testing.expectEqual(before.pages.cols, s.pages.cols);
        try testing.expectEqual(before.pages.rows, s.pages.rows);
        try testing.expectEqual(before.pages.total_rows, s.pages.total_rows);
        try testing.expectEqual(before.pages.viewport, s.pages.viewport);
        try testing.expectEqual(before_viewport_pin, s.pages.viewport_pin.*);
        try testing.expectEqual(before_tracked_pins, s.pages.countTrackedPins());
        if (std.valgrind.runningOnValgrind() > 0) {
            // This assertion deliberately compares the complete raw page,
            // including semantically irrelevant struct padding.
            std.valgrind.memcheck.makeMemDefined(before_page);
            std.valgrind.memcheck.makeMemDefined(
                s.pages.pages.first.?.page().memory,
            );
        }
        try testing.expectEqualSlices(
            u8,
            before_page,
            s.pages.pages.first.?.page().memory,
        );
        {
            try testing.expectEqual(
                before.kitty_images.dirty,
                s.kitty_images.dirty,
            );
        }
    }
}

test "Screen: resize cursor references when node survives" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 1000,
    });
    defer s.deinit();

    try s.setAttribute(.bold);
    try s.startHyperlink("https://example.com/", "resize");
    try s.testWriteString("abc");

    const original_node = s.cursor.page_pin.node;
    const original_serial = original_node.serial;
    {
        const page = original_node.page();
        try testing.expectEqual(
            4,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
        try testing.expectEqual(
            4,
            page.hyperlink_set.refCount(page.memory, s.cursor.hyperlink_id),
        );
    }

    // A row-only resize grows the existing page without replacing the
    // cursor's node. The temporary resize references must be released from
    // this page after the cursor state is restored.
    try s.resize(.{ .cols = 5, .rows = 4 });

    try testing.expectEqual(original_node, s.cursor.page_pin.node);
    try testing.expectEqual(original_serial, s.cursor.page_pin.node.serial);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(
            4,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
        try testing.expectEqual(
            4,
            page.hyperlink_set.refCount(page.memory, s.cursor.hyperlink_id),
        );
    }
}

test "Screen: resize cursor references when node is replaced" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 1000,
    });
    defer s.deinit();

    try s.setAttribute(.bold);
    try s.startHyperlink("https://example.com/", "resize");
    try s.testWriteString("abc");

    const original_node = s.cursor.page_pin.node;
    const original_serial = original_node.serial;
    {
        const page = original_node.page();
        try testing.expectEqual(
            4,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
        try testing.expectEqual(
            4,
            page.hyperlink_set.refCount(page.memory, s.cursor.hyperlink_id),
        );
    }

    // A column resize with reflow replaces the page and remaps the tracked
    // cursor pin. The old page owns the temporary references, so destroying
    // it must account for them without attempting to release them afterward.
    try s.resize(.{ .cols = 10, .rows = 3 });

    try testing.expect(
        s.cursor.page_pin.node != original_node or
            s.cursor.page_pin.node.serial != original_serial,
    );
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(
            4,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
        try testing.expectEqual(
            4,
            page.hyperlink_set.refCount(page.memory, s.cursor.hyperlink_id),
        );
    }
}

test "Screen: resize more rows and cols with wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 2, .rows = 4, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1A2B\n3C4D";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1A\n2B\n3C\n4D";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(.{ .cols = 5, .rows = 10 });

    // Cursor should move due to wrapping
    try testing.expectEqual(@as(size.CellCountInt, 3), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize less rows no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    s.cursorAbsolute(0, 0);
    const cursor = s.cursor;
    try s.resize(.{ .cols = 5, .rows = 1 });

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows moving cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Put our cursor on the last line
    s.cursorAbsolute(1, 2);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'I'), list_cell.cell.content.codepoint.data);
    }

    // Resize
    try s.resize(.{ .cols = 5, .rows = 1 });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.y);
}

test "Screen: resize less rows with empty scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 5, .rows = 1 });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize
    try s.resize(.{ .cols = 5, .rows = 1 });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows with full scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    const str = "00000\n1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    try testing.expectEqual(@as(size.CellCountInt, 4), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);

    // Resize
    try s.resize(.{ .cols = 5, .rows = 2 });

    // Cursor should stay in the same relative place (bottom of the
    // screen, same character).
    try testing.expectEqual(@as(size.CellCountInt, 4), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "00000\n1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols no reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1AB\n2EF\n3IJ";
    try s.testWriteString(str);

    s.cursorAbsolute(0, 0);
    const cursor = s.cursor;
    try s.resize(.{ .cols = 3, .rows = 3 });

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize less cols with reflow but row space" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);

    // Put our cursor on the end
    s.cursorAbsolute(4, 0);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'D'), list_cell.cell.content.codepoint.data);
    }

    try s.resize(.{ .cols = 3, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1AB\nCD";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1AB\nCD";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.y);
}

test "Screen: resize less cols with reflow with trimmed rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 3, .rows = 3 });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols with reflow with trimmed rows and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    const str = "3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 3, .rows = 3 });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "3IJ\nKL\n4AB\nCD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols with reflow previously wrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "3IJKL4ABCD5EFGH";
    try s.testWriteString(str);

    // Check
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(.{ .cols = 3, .rows = 3 });

    // {
    //     const contents = try s.testString(alloc, .viewport);
    //     defer alloc.free(contents);
    //     const expected = "CD\n5EF\nGH";
    //     try testing.expectEqualStrings(expected, contents);
    // }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "ABC\nD5E\nFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols with reflow and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1A\n2B\n3C\n4D\n5E";
    try s.testWriteString(str);

    // Put our cursor on the end
    s.cursorAbsolute(1, s.pages.rows - 1);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'E'), list_cell.cell.content.codepoint.data);
    }

    try s.resize(.{ .cols = 3, .rows = 3 });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3C\n4D\n5E";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
}

test "Screen: resize less cols with reflow previously wrapped and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL4ABCD5EFGH";
    try s.testWriteString(str);

    // Check
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Put our cursor on the end
    s.cursorAbsolute(s.pages.cols - 1, s.pages.rows - 1);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'H'), list_cell.cell.content.codepoint.data);
    }

    try s.resize(.{ .cols = 3, .rows = 3 });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "CD5\nEFG\nH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1AB\nCD2\nEFG\nH3I\nJKL\n4AB\nCD5\nEFG\nH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'H'), list_cell.cell.content.codepoint.data);
    }
}

test "Screen: resize less cols with scrollback keeps cursor row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1A\n2B\n3C\n4D\n5E";
    try s.testWriteString(str);

    // Lets do a scroll and clear operation
    try s.scrollClear();

    // Move our cursor to the beginning
    s.cursorAbsolute(0, 0);

    try s.resize(.{ .cols = 3, .rows = 3 });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.y);
}

test "Screen: resize more rows, less cols with reflow with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH3IJKL\n4MNOP";
    try s.testWriteString(str);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL\n4MNOP";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4MNOP";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(.{ .cols = 2, .rows = 10 });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "BC\nD\n2E\nFG\nH3\nIJ\nKL\n4M\nNO\nP";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1A\nBC\nD\n2E\nFG\nH3\nIJ\nKL\n4M\nNO\nP";
        try testing.expectEqualStrings(expected, contents);
    }
}

// This seems like it should work fine but for some reason in practice
// in the initial implementation I found this bug! This is a regression
// test for that.
test "Screen: resize more rows then shrink again" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const str = "1ABC";
    try s.testWriteString(str);

    // Grow
    try s.resize(.{ .cols = 5, .rows = 10 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Shrink
    try s.resize(.{ .cols = 5, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Grow again
    try s.resize(.{ .cols = 5, .rows = 10 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize less cols to eliminate wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 2, .rows = 1, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint.data);
    }

    // Resize to 1 column can't fit a wide char. So it should be deleted.
    try s.resize(.{ .cols = 1, .rows = 1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Screen: resize less cols to wrap wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 3, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "x😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint.data);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    try s.resize(.{ .cols = 2, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("x\n😀", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
        try testing.expect(list_cell.row.wrap);
    }
}

test "Screen: resize less cols to eliminate wide char with row space" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 2, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint.data);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    try s.resize(.{ .cols = 1, .rows = 2 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: resize less cols reflows cursor after wrapped text" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 50, .rows = 7, .max_scrollback_bytes = 0 });
    defer s.deinit();

    for (0..30) |_| try s.testWriteString("a");

    try testing.expectEqual(@as(usize, 0), s.cursor.y);
    try testing.expectEqual(@as(usize, 30), s.cursor.x);

    try s.resize(.{ .cols = 25, .rows = 7 });

    try testing.expectEqual(@as(usize, 1), s.cursor.y);
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
}

test "Screen: resize less cols reflows cursor after empty cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();

    try s.testWriteString("abc");
    s.cursorRight(6);

    try testing.expectEqual(@as(usize, 0), s.cursor.y);
    try testing.expectEqual(@as(usize, 9), s.cursor.x);

    try s.resize(.{ .cols = 5, .rows = 3 });

    try testing.expectEqual(@as(usize, 1), s.cursor.y);
    try testing.expectEqual(@as(usize, 4), s.cursor.x);
}

test "Screen: resize more cols with wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 3, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "  😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("  \n😀", contents);
    }

    // So this is the key point: we end up with a wide spacer head at
    // the end of row 1, then the emoji, then a wide spacer tail on row 2.
    // We should expect that if we resize to more cols, the wide spacer
    // head is replaced with the emoji.
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    try s.resize(.{ .cols = 4, .rows = 2 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint.data);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Screen: resize more cols with wide spacer head multiple lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 3, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "xxxyy😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("xxx\nyy\n😀", contents);
    }

    // Similar to the "wide spacer head" test, but this time we'er going
    // to increase our columns such that multiple rows are unwrapped.
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 2 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 2 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    try s.resize(.{ .cols = 8, .rows = 2 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 5, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint.data);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 6, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Screen: resize more cols requiring a wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 2, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "xx😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("xx\n😀", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    // This resizes to 3 columns, which isn't enough space for our wide
    // char to enter row 1. But we need to mark the wide spacer head on the
    // end of the first row since we're wrapping to the next row.
    try s.resize(.{ .cols = 3, .rows = 2 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("xx\n😀", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint.data);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Screen: resize more cols with cursor at prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();

    // zig fmt: off
    try s.testWriteString("ABCDE\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_eol });
    try s.testWriteString("echo");
    // zig fmt: on

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> echo";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(.{
        .cols = 20,
        .rows = 3,
        .prompt_redraw = .true,
    });

    // Cursor should not move
    try testing.expectEqual(6, s.cursor.x);
    try testing.expectEqual(1, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize more cols with cursor not at prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();

    // zig fmt: off
    try s.testWriteString("ABCDE\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_eol });
    try s.testWriteString("echo\n");
    try s.testWriteString("output");
    // zig fmt: on

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> echo\noutput";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(.{
        .cols = 20,
        .rows = 3,
        .prompt_redraw = .true,
    });

    // Cursor should not move
    try testing.expectEqual(6, s.cursor.x);
    try testing.expectEqual(2, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> echo\noutput";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize with prompt_redraw last clears only one line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 4, .max_scrollback_bytes = 5 });
    defer s.deinit();

    // zig fmt: off
    try s.testWriteString("ABCDE\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello\n");
    try s.testWriteString("world");
    // zig fmt: on

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> hello\nworld";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor is at end of "world" line with semantic_content = .input
    try s.resize(.{
        .cols = 20,
        .rows = 4,
        .prompt_redraw = .last,
    });

    // With .last, only the current line where cursor is should be cleared
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> hello";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize with prompt_redraw last multiline prompt clears only last line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 5 });
    defer s.deinit();

    // Create a 3-line prompt: 1 initial + 2 continuation lines
    // zig fmt: off
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("line1\n");
    s.cursorSetSemanticContent(.{ .prompt = .continuation });
    try s.testWriteString("line2\n");
    s.cursorSetSemanticContent(.{ .prompt = .continuation });
    try s.testWriteString("line3");
    // zig fmt: on

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "line1\nline2\nline3";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor is at end of line3 (the last continuation line)
    try s.resize(.{
        .cols = 30,
        .rows = 5,
        .prompt_redraw = .last,
    });

    // With .last, only line3 (where cursor is) should be cleared
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "line1\nline2";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: hyperlink cursor state on resize" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // This test depends on underlying PageList implementation so
    // it may be invalid one day. It's here to document/verify the
    // current behavior.

    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Start a hyperlink
    try s.startHyperlink("http://example.com", null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(1, page.hyperlink_set.count());
    }

    // Resize. Any column growth will trigger a page to be reallocated.
    try s.resize(.{ .cols = 10, .rows = 10 });
    try testing.expect(s.cursor.hyperlink_id != 0);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(1, page.hyperlink_set.count());
    }

    s.endHyperlink();
    try testing.expect(s.cursor.hyperlink_id == 0);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(0, page.hyperlink_set.count());
    }
}

test "Screen: increaseCapacity cursor style ref count preserved" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{
        .cols = 5,
        .rows = 5,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    try s.setAttribute(.bold);
    try s.testWriteString("1ABCD");

    // We should have one page and it should be our cursor page
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expect(s.pages.pages.first == s.cursor.page_pin.node);

    const old_style = s.cursor.style;

    {
        const page = s.pages.pages.last.?.page();
        // 5 chars + cursor = 6 refs
        try testing.expectEqual(
            6,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
    }

    // This forces the page to change via increaseCapacity.
    const new_node = try s.increaseCapacity(
        s.cursor.page_pin.node,
        .grapheme_bytes,
    );

    // Cursor's page_pin should now point to the new node
    try testing.expect(s.cursor.page_pin.node == new_node);

    // Verify cursor's page_cell and page_row are correctly reloaded from the pin
    const page_rac = s.cursor.page_pin.rowAndCell();
    try testing.expect(s.cursor.page_row == page_rac.row);
    try testing.expect(s.cursor.page_cell == page_rac.cell);

    // Style should be preserved
    try testing.expectEqual(old_style, s.cursor.style);
    try testing.expect(s.cursor.style_id != style.default_id);

    // After increaseCapacity, the 5 chars are cloned (5 refs) and
    // the cursor's style is re-added (1 ref) = 6 total.
    {
        const page = s.pages.pages.last.?.page();
        const ref_count = page.styles.refCount(page.memory, s.cursor.style_id);
        try testing.expectEqual(6, ref_count);
    }
}

test "Screen: increaseCapacity cursor hyperlink ref count preserved" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{
        .cols = 5,
        .rows = 5,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    try s.startHyperlink("https://example.com/", null);
    try s.testWriteString("1ABCD");

    // We should have one page and it should be our cursor page
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expect(s.pages.pages.first == s.cursor.page_pin.node);

    {
        const page = s.pages.pages.last.?.page();
        // Cursor has the hyperlink active = 1 count in hyperlink_set
        try testing.expectEqual(1, page.hyperlink_set.count());
        try testing.expect(s.cursor.hyperlink_id != 0);
        try testing.expect(s.cursor.hyperlink != null);
    }

    // This forces the page to change via increaseCapacity.
    _ = try s.increaseCapacity(
        s.cursor.page_pin.node,
        .grapheme_bytes,
    );

    // Hyperlink should be preserved with correct URI
    try testing.expect(s.cursor.hyperlink != null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    try testing.expectEqualStrings("https://example.com/", s.cursor.hyperlink.?.uri);

    // After increaseCapacity, the hyperlink is re-added to the new page.
    {
        const page = s.pages.pages.last.?.page();
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
}

test "Screen: increaseCapacity cursor with both style and hyperlink preserved" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{
        .cols = 5,
        .rows = 5,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();

    // Set both a non-default style AND an active hyperlink.
    // Write one character first with bold to mark the row as styled,
    // then start the hyperlink and write more characters.
    try s.setAttribute(.bold);
    try s.startHyperlink("https://example.com/", null);
    try s.testWriteString("1ABCD");

    // We should have one page and it should be our cursor page
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expect(s.pages.pages.first == s.cursor.page_pin.node);

    const old_style = s.cursor.style;

    {
        const page = s.pages.pages.last.?.page();
        // 5 chars + cursor = 6 refs for bold style
        try testing.expectEqual(
            6,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
        // Cursor has the hyperlink active = 1 count in hyperlink_set
        try testing.expectEqual(1, page.hyperlink_set.count());
        try testing.expect(s.cursor.style_id != style.default_id);
        try testing.expect(s.cursor.hyperlink_id != 0);
        try testing.expect(s.cursor.hyperlink != null);
    }

    // This forces the page to change via increaseCapacity.
    _ = try s.increaseCapacity(
        s.cursor.page_pin.node,
        .grapheme_bytes,
    );

    // Style should be preserved
    try testing.expectEqual(old_style, s.cursor.style);
    try testing.expect(s.cursor.style_id != style.default_id);

    // Hyperlink should be preserved with correct URI
    try testing.expect(s.cursor.hyperlink != null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    try testing.expectEqualStrings("https://example.com/", s.cursor.hyperlink.?.uri);

    // After increaseCapacity, both style and hyperlink are re-added to the new page.
    {
        const page = s.pages.pages.last.?.page();
        const ref_count = page.styles.refCount(page.memory, s.cursor.style_id);
        try testing.expectEqual(6, ref_count);
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
}

test "Screen: increaseCapacity non-cursor page returns early" {
    // Test that calling increaseCapacity on a page that is NOT the cursor's
    // page properly delegates to pages.increaseCapacity without doing the
    // extra cursor accounting (style/hyperlink re-adding).
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 10000,
    });
    defer s.deinit();

    // Set up a custom style and hyperlink on the cursor
    try s.setAttribute(.bold);
    try s.startHyperlink("https://example.com/", null);
    try s.testWriteString("Hello");

    // Store cursor state before growing pages
    const old_style = s.cursor.style;
    const old_style_id = s.cursor.style_id;
    const old_hyperlink = s.cursor.hyperlink;
    const old_hyperlink_id = s.cursor.hyperlink_id;

    // The cursor is on the first (and only) page
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);

    // Grow pages until we have multiple pages. The cursor's pin stays on
    // the first page since we're just adding rows.
    const first_page_node = s.pages.pages.first.?;
    first_page_node.page().pauseIntegrityChecks(true);
    for (0..first_page_node.capacity().rows - first_page_node.rows()) |_| {
        _ = try s.pages.grow();
    }
    first_page_node.page().pauseIntegrityChecks(false);
    _ = try s.pages.grow();

    // Now we have two pages
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    const second_page = s.pages.pages.last.?;

    // Cursor should still be on the first page (where it was created)
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try testing.expect(s.cursor.page_pin.node != second_page);

    const second_page_styles_cap = second_page.capacity().styles;
    const cursor_page_styles_cap = s.cursor.page_pin.node.capacity().styles;

    // Call increaseCapacity on the second page (NOT the cursor's page)
    const new_second_page = try s.increaseCapacity(second_page, .styles);

    // The second page should have increased capacity
    try testing.expectEqual(
        second_page_styles_cap * 2,
        new_second_page.capacity().styles,
    );

    // The cursor's page (first page) should be unchanged
    try testing.expectEqual(
        cursor_page_styles_cap,
        s.cursor.page_pin.node.capacity().styles,
    );

    // Cursor state should be completely unchanged since we didn't touch its page
    try testing.expectEqual(old_style, s.cursor.style);
    try testing.expectEqual(old_style_id, s.cursor.style_id);
    try testing.expectEqual(old_hyperlink, s.cursor.hyperlink);
    try testing.expectEqual(old_hyperlink_id, s.cursor.hyperlink_id);

    // Verify hyperlink is still valid
    try testing.expect(s.cursor.hyperlink != null);
    try testing.expectEqualStrings("https://example.com/", s.cursor.hyperlink.?.uri);
}

test "Screen: cursorDown to page with insufficient capacity" {
    // Regression test for https://github.com/ghostty-org/ghostty/issues/10282
    //
    // This test exposes a use-after-realloc bug in cursorDown (and similar
    // cursor movement functions). The bug pattern:
    //
    // 1. cursorDown creates a by-value copy of the pin via page_pin.down(n)
    // 2. cursorChangePin is called, which may trigger increaseCapacity
    //    if the target page's style map is full
    // 3. increaseCapacity frees the old page and creates a new one
    // 4. The local pin copy still points to the freed page
    // 5. rowAndCell() on the stale pin accesses freed memory

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // Small screen to make page boundary crossing easy to set up
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();

    // Scroll down enough to create a second page
    const start_page = s.pages.pages.last.?.page();
    const rem = start_page.capacity.rows;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try cursorDownOrScroll(&s);
    start_page.pauseIntegrityChecks(false);

    // Cursor should now be on a new page
    const new_page = s.cursor.page_pin.node.page();
    try testing.expect(start_page != new_page);

    // Fill new_page's style map to capacity. When we move INTO this page
    // with a style set, increaseCapacity will be triggered.
    {
        new_page.pauseIntegrityChecks(true);
        defer new_page.pauseIntegrityChecks(false);
        defer new_page.assertIntegrity();

        var n: u24 = 1;
        while (new_page.styles.add(
            new_page.memory,
            .{ .bg_color = .{ .rgb = @bitCast(n) } },
        )) |_| n += 1 else |_| {}
    }

    // Move cursor to start of active area and set a style
    s.cursorAbsolute(0, 0);
    try s.setAttribute(.bold);
    try testing.expect(s.cursor.style.flags.bold);
    try testing.expect(s.cursor.style_id != style.default_id);

    // Find the row just before the page boundary
    for (0..s.pages.rows - 1) |row| {
        s.cursorAbsolute(0, @intCast(row));
        const cur_node = s.cursor.page_pin.node;
        if (s.cursor.page_pin.down(1)) |next_pin| {
            if (next_pin.node != cur_node) {
                // Cursor is at 'row', moving down crosses to new_page
                try testing.expect(next_pin.node.page() == new_page);

                // This cursorDown triggers the bug: the local page_pin copy
                // becomes stale after increaseCapacity, causing rowAndCell()
                // to access freed memory.
                s.cursorDown(1);

                // If the fix is applied, verify correct state
                try testing.expect(s.cursor.y == row + 1);
                try testing.expect(s.cursor.style.flags.bold);

                break;
            }
        }
    } else {
        // Didn't find boundary
        try testing.expect(false);
    }
}

test "Screen setAttribute increases capacity when style map is full" {
    // Tests that setAttribute succeeds when the style map is full by
    // increasing page capacity. When capacity is at max and increaseCapacity
    // returns OutOfSpace, manualStyleUpdate will split the page instead.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // Use a small screen with multiple rows
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();

    // Write content to multiple rows
    try s.testWriteString("line1\nline2\nline3\nline4\nline5");

    // Get the page and fill its style map to capacity
    const page = s.cursor.page_pin.node.page();
    const original_styles_capacity = page.capacity.styles;

    // Fill the style map to capacity using the StyleSet's layout capacity
    // which accounts for the load factor
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

    // Now try to set a new unique attribute that would require a new style slot
    // This should succeed by increasing capacity (or splitting if at max capacity)
    try s.setAttribute(.bold);

    // The style should have been applied (bold flag set)
    try testing.expect(s.cursor.style.flags.bold);

    // The cursor should have a valid non-default style_id
    try testing.expect(s.cursor.style_id != style.default_id);

    // Either the capacity increased or the page was split/changed
    const current_page = s.cursor.page_pin.node.page();
    const capacity_increased = current_page.capacity.styles > original_styles_capacity;
    const page_changed = current_page != page;
    try testing.expect(capacity_increased or page_changed);
}
