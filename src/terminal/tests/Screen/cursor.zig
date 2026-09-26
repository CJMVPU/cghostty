//! Screen cursor regression tests.
const cursorDownOrScroll = support.cursorDownOrScroll;
const support = @import("support.zig");
const Screen = support.Screen;
const std = support.std;
const PageList = support.PageList;
const pagepkg = support.pagepkg;
const point = support.point;
const size = support.size;
const style = support.style;
const Page = support.Page;
const Cell = support.Cell;
const Pin = support.Pin;
const init = support.init;

test "Screen forwards optional scrollback limits" {
    const testing = std.testing;
    const max_lines: usize = 123;
    var s = try init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = max_lines,
    });
    defer s.deinit();

    try testing.expectEqual(
        std.math.maxInt(usize),
        s.pages.limits.bytes.explicit,
    );
    try testing.expectEqual(max_lines, s.pages.limits.lines.explicit);
    try testing.expect(!s.no_scrollback);
}

test "Screen reset cursor pin is not garbage" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    try s.testWriteString("hello, world");

    // The page reset marks every tracked pin garbage but the screen
    // keeps using the cursor pin, so it must come back clean: anything
    // that copies it (e.g. Kitty image placements) would otherwise be
    // born garbage and reaped.
    s.reset();
    try testing.expect(!s.cursor.page_pin.garbage);
}

test "Screen read and write scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 2, .max_scrollback_bytes = 1000 });
    defer s.deinit();

    try s.testWriteString("hello\nworld\ntest");
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("hello\nworld\ntest", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("world\ntest", str);
    }
}

test "Screen read and write no scrollback small" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();

    try s.testWriteString("hello\nworld\ntest");
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("world\ntest", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("world\ntest", str);
    }
}

test "Screen read and write no scrollback large" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();

    for (0..1_000) |i| {
        var buf: [128]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{}\n", .{i});
        try s.testWriteString(str);
    }
    try s.testWriteString("1000");

    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("999\n1000", str);
    }
}

test "Screen cursorCopy x/y" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursorAbsolute(2, 3);
    try testing.expect(s.cursor.x == 2);
    try testing.expect(s.cursor.y == 3);

    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s2.deinit();
    try s2.cursorCopy(s.cursor, .{});
    try testing.expect(s2.cursor.x == 2);
    try testing.expect(s2.cursor.y == 3);
    try s2.testWriteString("Hello");

    {
        const str = try s2.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("\n\n\n  Hello", str);
    }
}

test "Screen cursorCopy style deref" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();

    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s2.deinit();
    const page = s2.cursor.page_pin.node.page();

    // Bold should create our style
    try s2.setAttribute(.{ .bold = {} });
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try testing.expect(s2.cursor.style.flags.bold);

    // Copy default style, should release our style
    try s2.cursorCopy(s.cursor, .{});
    try testing.expect(!s2.cursor.style.flags.bold);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}

test "Screen cursorCopy style deref new page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();

    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 2048 });
    defer s2.deinit();

    // We need to get the cursor on a new page.
    const first_page_size = s2.pages.pages.first.?.capacity().rows;

    // Fill the scrollback with blank lines until
    // there are only 5 rows left on the first page.
    s2.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 5) |_| {
        try s2.testWriteString("\n");
    }
    s2.pages.pages.first.?.page().pauseIntegrityChecks(false);

    try s2.testWriteString("1\n2\n3\n4\n5\n6\n7\n8\n9\n10");

    // s2.pages.diagram(...):
    //
    //      +----------+ = PAGE 0
    //  ... :          :
    //     +-------------+ ACTIVE
    // 4300 |1         | | 0
    // 4301 |2         | | 1
    // 4302 |3         | | 2
    // 4303 |4         | | 3
    // 4304 |5         | | 4
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |6         | | 5
    //    1 |7         | | 6
    //    2 |8         | | 7
    //    3 |9         | | 8
    //    4 |10        | | 9
    //      :  ^       : : = PIN 0
    //      +----------+ :
    //     +-------------+

    // This should be PAGE 1
    const page = s2.cursor.page_pin.node.page();

    // It should be the last page in the list.
    try testing.expectEqual(s2.pages.pages.last.?.page(), page);
    // It should have a previous page.
    try testing.expect(s2.cursor.page_pin.node.prev != null);

    // The cursor should be at 2, 9
    try testing.expect(s2.cursor.x == 2);
    try testing.expect(s2.cursor.y == 9);

    // Bold should create our style in page 1.
    try s2.setAttribute(.{ .bold = {} });
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try testing.expect(s2.cursor.style.flags.bold);

    // Copy the cursor for the first screen. This should release
    // the style from page 1 and move the cursor back to page 0.
    try s2.cursorCopy(s.cursor, .{});
    try testing.expect(!s2.cursor.style.flags.bold);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
    // The page after the page the cursor is now in should be page 1.
    try testing.expectEqual(page, s2.cursor.page_pin.node.next.?.page());
    // The cursor should be at 0, 0
    try testing.expect(s2.cursor.x == 0);
    try testing.expect(s2.cursor.y == 0);
}

test "Screen cursorCopy style copy" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.setAttribute(.{ .bold = {} });

    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s2.deinit();
    const page = s2.cursor.page_pin.node.page();
    try s2.cursorCopy(s.cursor, .{});
    try testing.expect(s2.cursor.style.flags.bold);
    try testing.expectEqual(@as(usize, 1), page.styles.count());
}

test "Screen cursorCopy hyperlink deref" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();

    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s2.deinit();
    const page = s2.cursor.page_pin.node.page();

    // Create a hyperlink for the cursor.
    try s2.startHyperlink("https://example.com/", null);
    try testing.expectEqual(@as(usize, 1), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id != 0);

    // Copy a cursor with no hyperlink, should release our hyperlink.
    try s2.cursorCopy(s.cursor, .{});
    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);
}

// The cursor style and hyperlink IDs are only meaningful within the page
// the cursor pin points at. scrollClear can move the active area onto a
// later page while the cursor pin stays with its content on an earlier
// page (now scrollback), so the reset in cursorReload must migrate both
// references to the destination page. It previously replaced the pin
// directly and then released the old style ID on the new page.
test "Screen scrollClear across pages migrates cursor style and hyperlink" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer s.deinit();

    // Fill the first page so the active area spans two pages.
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 5) |_| {
        try s.testWriteString("\n");
    }
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.testWriteString("1\n2\n3\n4\n5\n6\n7\n8\n9\n10");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Move the cursor to the top of the active area, which is on the
    // first page, and give it a style and a hyperlink there.
    s.cursorAbsolute(0, 0);
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try s.setAttribute(.{ .bold = {} });
    try s.startHyperlink("https://example.com/", null);

    const old_page: *Page = s.cursor.page_pin.node.page();
    const old_style_id = s.cursor.style_id;
    const old_hyperlink_id = s.cursor.hyperlink_id;
    try testing.expect(old_style_id != style.default_id);
    try testing.expect(old_hyperlink_id != 0);

    // All ten active rows are non-empty, so this moves the active area
    // fully onto the second page while the cursor pin stays with its
    // old row, which is now scrollback.
    try s.scrollClear();

    // The cursor was moved to the new active top-left on the second
    // page with its style and hyperlink references rebuilt there.
    const new_page: *Page = s.cursor.page_pin.node.page();
    try testing.expect(new_page != old_page);
    try testing.expect(s.cursor.style_id != style.default_id);
    try testing.expect(s.cursor.hyperlink_id != 0);
    try testing.expect(new_page.styles.refCount(
        new_page.memory,
        s.cursor.style_id,
    ) > 0);
    try testing.expect(new_page.hyperlink_set.refCount(
        new_page.memory,
        s.cursor.hyperlink_id,
    ) > 0);

    // The cursor's references on the old page were released. Nothing
    // else referenced either entry, so both are dead there now.
    try testing.expectEqual(0, old_page.styles.refCount(
        old_page.memory,
        old_style_id,
    ));
    try testing.expectEqual(0, old_page.hyperlink_set.refCount(
        old_page.memory,
        old_hyperlink_id,
    ));

    // Printing attaches the migrated style and hyperlink to a cell.
    try s.testWriteString("B");
}

test "Screen cursorCopy hyperlink deref new page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();

    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 2048 });
    defer s2.deinit();

    // We need to get the cursor on a new page.
    const first_page_size = s2.pages.pages.first.?.capacity().rows;

    // Fill the scrollback with blank lines until
    // there are only 5 rows left on the first page.
    s2.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 5) |_| {
        try s2.testWriteString("\n");
    }
    s2.pages.pages.first.?.page().pauseIntegrityChecks(false);

    try s2.testWriteString("1\n2\n3\n4\n5\n6\n7\n8\n9\n10");

    // s2.pages.diagram(...):
    //
    //      +----------+ = PAGE 0
    //  ... :          :
    //     +-------------+ ACTIVE
    // 4300 |1         | | 0
    // 4301 |2         | | 1
    // 4302 |3         | | 2
    // 4303 |4         | | 3
    // 4304 |5         | | 4
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |6         | | 5
    //    1 |7         | | 6
    //    2 |8         | | 7
    //    3 |9         | | 8
    //    4 |10        | | 9
    //      :  ^       : : = PIN 0
    //      +----------+ :
    //     +-------------+

    // This should be PAGE 1
    const page = s2.cursor.page_pin.node.page();

    // It should be the last page in the list.
    try testing.expectEqual(s2.pages.pages.last.?.page(), page);
    // It should have a previous page.
    try testing.expect(s2.cursor.page_pin.node.prev != null);

    // The cursor should be at 2, 9
    try testing.expect(s2.cursor.x == 2);
    try testing.expect(s2.cursor.y == 9);

    // Create a hyperlink for the cursor, should be in page 1.
    try s2.startHyperlink("https://example.com/", null);
    try testing.expectEqual(@as(usize, 1), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id != 0);

    // Copy the cursor for the first screen. This should release
    // the hyperlink from page 1 and move the cursor back to page 0.
    try s2.cursorCopy(s.cursor, .{});
    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);
    // The page after the page the cursor is now in should be page 1.
    try testing.expectEqual(page, s2.cursor.page_pin.node.next.?.page());
    // The cursor should be at 0, 0
    try testing.expect(s2.cursor.x == 0);
    try testing.expect(s2.cursor.y == 0);
}

test "Screen cursorCopy hyperlink copy" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Create a hyperlink for the cursor.
    try s.startHyperlink("https://example.com/", null);
    try testing.expectEqual(@as(usize, 1), s.cursor.page_pin.node.page().hyperlink_set.count());
    try testing.expect(s.cursor.hyperlink_id != 0);

    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s2.deinit();
    const page = s2.cursor.page_pin.node.page();

    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);

    // Copy the cursor with the hyperlink.
    try s2.cursorCopy(s.cursor, .{});
    try testing.expectEqual(@as(usize, 1), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id != 0);
}

test "Screen cursorCopy hyperlink copy disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Create a hyperlink for the cursor.
    try s.startHyperlink("https://example.com/", null);
    try testing.expectEqual(@as(usize, 1), s.cursor.page_pin.node.page().hyperlink_set.count());
    try testing.expect(s.cursor.hyperlink_id != 0);

    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s2.deinit();
    const page = s2.cursor.page_pin.node.page();

    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);

    // Copy the cursor with the hyperlink.
    try s2.cursorCopy(s.cursor, .{ .hyperlink = false });
    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);
}

test "Screen: cursorCellEndOfPrev across mixed-width pages" {
    const testing = std.testing;
    var s = try init(testing.io, testing.allocator, .{
        .cols = 4,
        .rows = 2,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();

    try s.testWriteString("ABCDE");
    const first = s.pages.pages.first.?;
    try s.pages.split(.{ .node = first, .y = 1 });
    s.cursorReload();
    const second = first.next.?;
    first.page().size.cols = 2;

    try testing.expectEqual(second, s.cursor.page_pin.node);
    const expected = (Pin{ .node = first, .x = 1 }).rowAndCell().cell;
    try testing.expectEqual(expected, s.cursorCellEndOfPrev());
}

test "Screen: cursorDown across pages preserves style" {
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

    // We need our page to change for this test o make sense. If this
    // assertion fails then the bug is in the test: we should be scrolling
    // above enough for a new page to show up.
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expect(start_page != page);
    }

    // Scroll back to the previous page
    s.cursorUp(1);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expect(start_page == page);
    }

    // Go back up, set a style
    try s.setAttribute(.{ .bold = {} });
    {
        const page = s.cursor.page_pin.node.page();
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }

    // Go back down into the next page and we should have that style
    s.cursorDown(1);
    {
        const page = s.cursor.page_pin.node.page();
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
}

test "Screen: cursorUp across pages preserves style" {
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

    // We need our page to change for this test o make sense. If this
    // assertion fails then the bug is in the test: we should be scrolling
    // above enough for a new page to show up.
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expect(start_page != page);
    }

    // Go back up, set a style
    try s.setAttribute(.{ .bold = {} });
    {
        const page = s.cursor.page_pin.node.page();
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }

    // Go back down into the prev page and we should have that style
    s.cursorUp(1);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expect(start_page == page);

        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
}

test "Screen: cursorAbsolute across pages preserves style" {
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

    // We need our page to change for this test o make sense. If this
    // assertion fails then the bug is in the test: we should be scrolling
    // above enough for a new page to show up.
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expect(start_page != page);
    }

    // Go back up, set a style
    try s.setAttribute(.{ .bold = {} });
    {
        const page = s.cursor.page_pin.node.page();
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }

    // Go back down into the prev page and we should have that style
    s.cursorAbsolute(1, 1);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expect(start_page == page);

        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
}

test "Screen: scrolling" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Scroll down, should still be bottom
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 2 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Everything is dirty because we have no scrollback
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    // Scrolling to the bottom does nothing
    s.scroll(.{ .active = {} });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: scrolling with a single-row screen no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 1, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD");

    // Scroll down, should still be bottom
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }

    // Screen should be dirty
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
}

test "Screen: scrolling with a single-row screen with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 1, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD");

    // Scroll down, should still be bottom
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }

    // Active should be dirty
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    // Scrollback also dirty because cursor moved from there
    try testing.expect(s.pages.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    s.scroll(.{ .delta_row = -1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}

test "Screen: scrolling across pages preserves style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.setAttribute(.{ .bold = {} });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    const start_page = s.pages.pages.last.?.page();

    // Scroll down enough to go to another page
    const rem = start_page.capacity.rows - start_page.size.rows + 1;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try cursorDownOrScroll(&s);
    start_page.pauseIntegrityChecks(false);

    // We need our page to change for this test o make sense. If this
    // assertion fails then the bug is in the test: we should be scrolling
    // above enough for a new page to show up.
    const page = s.pages.pages.last.?.page();
    try testing.expect(start_page != page);

    const styleval = page.styles.get(
        page.memory,
        s.cursor.style_id,
    );
    try testing.expect(styleval.flags.bold);
}

test "Screen: scroll down from 0" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Scrolling up does nothing, but allows it
    s.scroll(.{ .delta_row = -1 });
    try testing.expect(s.pages.viewport == .active);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

test "Screen: scrollback various cases" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.cursorDownScroll();

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom
    s.scroll(.{ .active = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling back should make it visible again
    s.scroll(.{ .delta_row = -1 });
    try testing.expect(s.pages.viewport != .active);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scrolling back again should do nothing
    s.scroll(.{ .delta_row = -1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom
    s.scroll(.{ .active = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling forward with no grow should do nothing
    s.scroll(.{ .delta_row = 1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the top should work
    s.scroll(.{ .top = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Should be able to easily clear active area only
    s.clearRows(.{ .active = .{} }, null, false);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }

    // Scrolling to the bottom
    s.scroll(.{ .active = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: scrollback with multi-row delta" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH\n6IJKL");

    // Scroll to top
    s.scroll(.{ .top = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scroll down multiple
    s.scroll(.{ .delta_row = 5 });
    try testing.expect(s.pages.viewport == .active);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}

test "Screen: scrollback empty" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 50 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta_row = 1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

test "Screen: scrollback doesn't move viewport if not at bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH");

    // First test: we scroll up by 1, so we're not at the bottom anymore.
    s.scroll(.{ .delta_row = -1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n4ABCD", contents);
    }

    // Next, we scroll back down by 1, this grows the scrollback but we
    // shouldn't move.
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n4ABCD", contents);
    }

    // Scroll again, this clears scrollback so we should move viewports
    // but still see the same thing since our original view fits.
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n4ABCD", contents);
    }
}

test "Screen: cursorScrollRegionUp simple" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4MNOP\n5QRST");

    // Scroll a region ending at row 2 (zero-indexed) up by one. This
    // emulates a scroll region of rows 0-2 with the cursor at the
    // region bottom.
    s.cursorAbsolute(1, 2);
    try s.cursorScrollRegionUp(2);

    // The cursor stays in place, on the new blank row.
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);

    // Rows in the region scrolled, rows below are unchanged, and
    // nothing was moved into scrollback.
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n\n4MNOP\n5QRST", contents);
    }
}

test "Screen: cursorScrollRegionUp renews page generation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4MNOP\n5QRST");
    s.cursorAbsolute(0, 2);

    const node = s.cursor.page_pin.node;
    const serial = node.serial;
    try s.cursorScrollRegionUp(2);

    try testing.expect(!s.pages.nodeIsValid(node, serial));
}

test "Screen: cursorScrollRegionUp region spans pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();

    // We need to get the cursor to a new page
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");

    // At this point:
    //      +----------+ = PAGE 0
    //  ... :          :
    //     +-------------+ ACTIVE
    // 4305 |1A00000000| | 0
    // 4306 |2B00000000| | 1
    // 4307 |3C00000000| | 2
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |4D00000000| | 3
    //      :^         : : = PIN 0
    //    1 |5E00000000| | 4
    //      +----------+ :
    //     +-------------+

    // Move the cursor to the first row of the second page and give it
    // a non-default style. This is important: it verifies that the
    // cursor's style ref stays accounted on the correct page even
    // though eraseRowBounded moves the cursor's tracked pin across
    // the page boundary.
    s.cursorAbsolute(0, 3);
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.last.?);
    try testing.expectEqual(@as(usize, 0), s.cursor.page_pin.y);

    // Scroll a region of active rows 1-3 with the cursor at the region
    // bottom. The region spans the page boundary so this exercises the
    // slow path.
    try s.cursorScrollRegionUp(2);

    // The cursor stays in place, on the new blank row.
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 3), s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1A\n3C\n4D\n\n5E", contents);
    }

    // Our cursor style must remain usable: write a styled cell and
    // verify the style ref counting is intact on the cursor's page.
    try s.testWriteString("X");
    {
        const page = s.cursor.page_pin.node.page();
        const styles = page.styles.count();
        try testing.expectEqual(@as(usize, 1), styles);
    }
}

test "Screen: cursorScrollRegionUp region spans pages with background SGR" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();

    // We need to get the cursor to a new page. See the previous test
    // for a diagram of the page layout.
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");

    s.cursorAbsolute(0, 3);
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 0xFF, .g = 0, .b = 0 } });
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.last.?);
    try testing.expectEqual(@as(usize, 0), s.cursor.page_pin.y);

    try s.cursorScrollRegionUp(2);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1A\n3C\n4D\n\n5E", contents);
    }

    // The new blank row must be filled with our background color.
    for (0..s.pages.cols) |x| {
        const list_cell = s.pages.getCell(.{ .active = .{
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

test "Screen: cursorScrollRegionUp with styled erased row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Write a styled row at the top so the erased row has managed
    // memory that must be released.
    try s.setAttribute(.{ .bold = {} });
    try s.testWriteString("1ABCD");
    try s.setAttribute(.{ .unset = {} });
    try s.testWriteString("\n2EFGH\n3IJKL");

    s.cursorAbsolute(0, 2);
    try s.cursorScrollRegionUp(2);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // The style should be gone from the page since the only user
    // was the erased row.
    const page = s.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}

test "Screen: scrolling moves viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta_row = -2 });

    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n1ABCD", contents);
    }

    {
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, s.pages.getTopLeft(.viewport)));
    }
}

test "Screen: scrolling when viewport is pruned" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 215, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();

    // Write some to create scrollback and move back into our scrollback.
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta_row = -2 });

    // Our viewport is now somewhere pinned. Create so much scrollback
    // that we prune it.
    try s.testWriteString("\n");
    for (0..1000) |_| try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    {
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, s.pages.getTopLeft(.viewport)));
    }
}

test "Screen: scroll and clear full screen" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

test "Screen: scroll and clear partial screen" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }

    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
}

test "Screen: scroll and clear empty screen" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: scroll and clear ignore blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");
    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }

    // Move back to top-left
    s.cursorAbsolute(0, 0);

    // Write and clear
    try s.testWriteString("3ABCD\n");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3ABCD", contents);
    }

    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }

    // Move back to top-left
    s.cursorAbsolute(0, 0);
    try s.testWriteString("X");

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3ABCD\nX", contents);
    }
}

test "Screen: scroll above same page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();

    // At this point:
    //  +-------------+ ACTIVE
    //   +----------+ : = PAGE 0
    // 0 |1ABCD00000| | 0
    // 1 |2EFGH00000| | 1
    //   :^         : : = PIN 0
    // 2 |3IJKL00000| | 2
    //   +----------+ :
    //  +-------------+

    const node = s.cursor.page_pin.node;
    const serial = node.serial;
    try s.cursorScrollAbove();
    try testing.expect(!s.pages.nodeIsValid(node, serial));

    //   +----------+ = PAGE 0
    // 0 |1ABCD00000|
    //  +-------------+ ACTIVE
    // 1 |2EFGH00000| | 0
    // 2 |          | | 1
    //   :^         : : = PIN 0
    // 3 |3IJKL00000| | 2
    //   +----------+ :
    //  +-------------+

    // try s.pages.diagram(std.io.getStdErr().writer());

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n\n3IJKL", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Page 0 row 1 (active row 0) is dirty because the cursor moved off of it.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    // Page 0 row 2 (active row 1) is dirty because it was cleared.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    // Page 0 row 3 (active row 2) is dirty because it's new.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
}

test "Screen: scroll above same page but cursor on previous page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();

    // We need to get the cursor to a new page
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);

    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();

    // Ensure we're still on the first page and have a second
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try testing.expect(s.pages.pages.first.?.next != null);

    // At this point:
    //      +----------+ = PAGE 0
    //  ... :          :
    //     +-------------+ ACTIVE
    // 4305 |1A00000000| | 0
    // 4306 |2B00000000| | 1
    //      :^         : : = PIN 0
    // 4307 |3C00000000| | 2
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |4D00000000| | 3
    //    1 |5E00000000| | 4
    //      +----------+ :
    //     +-------------+

    const first_node = s.pages.pages.first.?;
    const second_node = first_node.next.?;
    const first_serial = first_node.serial;
    const second_serial = second_node.serial;
    try s.cursorScrollAbove();
    try testing.expect(!s.pages.nodeIsValid(first_node, first_serial));
    try testing.expect(!s.pages.nodeIsValid(second_node, second_serial));

    //      +----------+ = PAGE 0
    //  ... :          :
    // 4305 |1A00000000|
    //     +-------------+ ACTIVE
    // 4306 |2B00000000| | 0
    // 4307 |          | | 1
    //      :^         : : = PIN 0
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |3C00000000| | 2
    //    1 |4D00000000| | 3
    //    2 |5E00000000| | 4
    //      +----------+ :
    //     +-------------+

    // try s.pages.diagram(std.io.getStdErr().writer());

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2B\n\n3C\n4D\n5E", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Page 0's penultimate row is dirty because the cursor moved off of it.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    // The rest of the rows are dirty because they've been modified or are new.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));
}

test "Screen: scroll above same page but cursor on previous page last row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();

    // We need to get the cursor to a new page
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 2) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);

    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();

    // Ensure we're still on the first page and have a second
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try testing.expect(s.pages.pages.first.?.next != null);

    // At this point:
    //      +----------+ = PAGE 0
    //  ... :          :
    //     +-------------+ ACTIVE
    // 4306 |1A00000000| | 0
    // 4307 |2B00000000| | 1
    //      :^         : : = PIN 0
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |3C00000000| | 2
    //    1 |4D00000000| | 3
    //    2 |5E00000000| | 4
    //      +----------+ :
    //     +-------------+

    try s.cursorScrollAbove();

    //      +----------+ = PAGE 0
    //  ... :          :
    // 4306 |1A00000000|
    //     +-------------+ ACTIVE
    // 4307 |2B00000000| | 0
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |          | | 1
    //      :^         : : = PIN 0
    //    1 |3C00000000| | 2
    //    2 |4D00000000| | 3
    //    3 |5E00000000| | 4
    //      +----------+ :
    //     +-------------+

    // try s.pages.diagram(std.io.getStdErr().writer());

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2B\n\n3C\n4D\n5E", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Page 0's final row is dirty because the cursor moved off of it.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    // Page 1's rows are all dirty because every row was moved.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));

    // Attempt to clear the style from the cursor and
    // then assert the integrity of both of our pages.
    //
    // This catches a case of memory corruption where the cursor
    // is moved between pages without accounting for style refs.
    try s.setAttribute(.{ .reset_bg = {} });
    s.pages.pages.first.?.page().assertIntegrity();
    s.pages.pages.last.?.page().assertIntegrity();
}

test "Screen: scroll above creates new page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();

    // We need to get the cursor to a new page
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);

    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();

    // Ensure we're still on the first page
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);

    // At this point:
    //      +----------+ = PAGE 0
    //  ... :          :
    //     +-------------+ ACTIVE
    // 4305 |1ABCD00000| | 0
    // 4306 |2EFGH00000| | 1
    //      :^         : : = PIN 0
    // 4307 |3IJKL00000| | 2
    //      +----------+ :
    //     +-------------+
    const node = s.pages.pages.first.?;
    const serial = node.serial;
    try s.cursorScrollAbove();
    try testing.expect(!s.pages.nodeIsValid(node, serial));

    //      +----------+ = PAGE 0
    //  ... :          :
    // 4305 |1ABCD00000|
    //     +-------------+ ACTIVE
    // 4306 |2EFGH00000| | 0
    // 4307 |          | | 1
    //      :^         : : = PIN 0
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |3IJKL00000| | 2
    //      +----------+ :
    //     +-------------+

    // try s.pages.diagram(std.io.getStdErr().writer());

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n\n3IJKL", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Page 0's penultimate row is dirty because the cursor moved off of it.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    // Page 0's final row is dirty because it was cleared.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    // Page 1's row is dirty because it's new.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
}

test "Screen: scroll above with cursor on non-final row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 4, .max_scrollback_bytes = 10 });
    defer s.deinit();

    // Get the cursor to be 2 rows above a new page
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);

    // Write 3 lines of text, forcing the last line into the first
    // row of a new page. Move our cursor onto the previous page.
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1AB\n2BC\n3DE\n4FG");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();

    // Ensure we're still on the first page. So our cursor is on the first
    // page but we have two pages of data.
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);

    //      +----------+ = PAGE 0
    //  ... :          :
    //     +-------------+ ACTIVE
    // 4305 |1AB0000000| | 0
    // 4306 |2BC0000000| | 1
    //      :^         : : = PIN 0
    // 4307 |3DE0000000| | 2
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |4FG0000000| | 3
    //      +----------+ :
    //     +-------------+
    try s.cursorScrollAbove();

    //     +----------+ = PAGE 0
    //  ... :          :
    // 4305 |1AB0000000|
    //     +-------------+ ACTIVE
    // 4306 |2BC0000000| | 0
    // 4307 |          | | 1
    //      :^         : : = PIN 0
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |3DE0000000| | 2
    //    1 |4FG0000000| | 3
    //      +----------+ :
    //     +-------------+
    // try s.pages.diagram(std.io.getStdErr().writer());

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2BC\n\n3DE\n4FG", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Page 0's penultimate row is dirty because the cursor moved off of it.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    // Page 0's final row is dirty because it was cleared.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    // Page 1's row is dirty because it's new.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
}

test "Screen: scroll above no scrollback bottom of page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();

    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);

    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();

    // At this point:
    //  +-------------+ ACTIVE
    //   +----------+ : = PAGE 0
    // 0 |1ABCD00000| | 0
    // 1 |2EFGH00000| | 1
    //   :^         : : = PIN 0
    // 2 |3IJKL00000| | 2
    //   +----------+ :
    //  +-------------+

    try s.cursorScrollAbove();

    //   +----------+ = PAGE 0
    // 0 |1ABCD00000|
    //  +-------------+ ACTIVE
    // 1 |2EFGH00000| | 0
    // 2 |          | | 1
    //   :^         : : = PIN 0
    // 3 |3IJKL00000| | 2
    //   +----------+ :
    //  +-------------+

    //try s.pages.diagram(std.io.getStdErr().writer());

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n\n3IJKL", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Page 0 row 1 (active row 0) is dirty because the cursor moved off of it.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    // Page 0 row 2 (active row 1) is dirty because it was cleared.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    // Page 0 row 3 (active row 2) is dirty because it is new.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
}

test "Screen: scroll above hyperlink-dense row to fresh page" {
    // Regression test for https://github.com/ghostty-org/ghostty/discussions/13160
    //
    // When a scroll-above operation pushes a row carrying more unique
    // hyperlinks than a fresh page's default hyperlink capacity across
    // a page boundary, the cross-page row clone must increase the
    // destination page's capacity (like insertLines/deleteLines do)
    // rather than error out mid-operation, which leaves the page list
    // half-mutated and aborts later (e.g. in clearCells).
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10000 });
    defer s.deinit();

    // Fill the first page so it is exactly full and the cursor is on
    // its last row (which is also the bottom row of the active area).
    // The next grow() will then allocate a fresh page.
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expectEqual(
        s.pages.pages.first.?.capacity().rows,
        s.pages.pages.first.?.page().size.rows,
    );
    try testing.expectEqual(s.pages.rows - 1, s.cursor.y);

    // Fill the bottom row with unique hyperlinks: more than a fresh
    // page can hold with default hyperlink capacity.
    for (0..s.pages.cols) |i| {
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{i});
        try s.startHyperlink(uri, null);
        try s.testWriteString("A");
        s.endHyperlink();
    }
    try testing.expectEqual(
        @as(usize, s.pages.cols),
        s.cursor.page_pin.node.page().hyperlink_set.count(),
    );

    // Move the cursor above the bottom row and scroll. The dense row is
    // pushed across the page boundary into the freshly allocated page.
    s.cursorAbsolute(0, 1);
    try s.cursorScrollAbove();

    // We must have created a second page and the dense row must now be
    // the top row of that page.
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // All hyperlinks must have survived the scroll intact: every cell
    // flagged as a hyperlink must resolve to a real entry in its page's
    // hyperlink map. A half-applied scroll leaves cells whose hyperlink
    // flag is set but that have no map entry, which aborts in
    // clearCells later.
    var node_: ?*PageList.List.Node = s.pages.pages.first;
    while (node_) |node| : (node_ = node.next) {
        const page: *Page = node.page();
        page.assertIntegrity();
        for (0..page.size.rows) |y| {
            const row = page.getRow(y);
            if (!row.hyperlink) continue;
            for (page.getCells(row)) |*cell| {
                if (!cell.hyperlink) continue;
                try testing.expect(page.lookupHyperlink(cell) != null);
            }
        }
    }
    {
        const last_page: *Page = s.pages.pages.last.?.page();
        try testing.expectEqual(
            @as(usize, s.pages.cols),
            last_page.hyperlink_set.count(),
        );
    }

    // The dense row is still the bottom row of the active area.
    for (0..s.pages.cols) |x| {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 4,
        } }).?;
        try testing.expect(list_cell.cell.hyperlink);
        const page: *Page = list_cell.node.page();
        const id = page.lookupHyperlink(list_cell.cell).?;
        const link = page.hyperlink_set.get(page.memory, id);
        var buf: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{x});
        try testing.expectEqualStrings(expected, link.uri.slice(page.memory));
    }
}

test "Screen: scroll above hyperlink-dense row to existing page" {
    // Same as the fresh page variant above but the destination page
    // already exists (fresh_node == null path in cursorScrollAboveRotate).
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10000 });
    defer s.deinit();

    // Fill the first page so it is exactly full and the cursor is on
    // its last row.
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try testing.expectEqual(s.pages.rows - 1, s.cursor.y);

    // Fill the last row of the first page with unique hyperlinks:
    // more than a page can hold with default hyperlink capacity.
    for (0..s.pages.cols) |i| {
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{i});
        try s.startHyperlink(uri, null);
        try s.testWriteString("A");
        s.endHyperlink();
    }

    // Scroll twice so the active area straddles the page boundary:
    // the last two active rows are on a second page while the dense
    // row remains the last row of the first page.
    try s.testWriteString("\n\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.last.?);

    // Move the cursor to an active row that is still on the first page
    // and above the dense row, then scroll. grow() has capacity in the
    // last page so no fresh page is allocated, but the dense row still
    // crosses the page boundary during the rotate.
    s.cursorAbsolute(0, 0);
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try s.cursorScrollAbove();

    // All hyperlinks must have survived the scroll intact: every cell
    // flagged as a hyperlink must resolve to a real entry in its page's
    // hyperlink map.
    var node_: ?*PageList.List.Node = s.pages.pages.first;
    while (node_) |node| : (node_ = node.next) {
        const page: *Page = node.page();
        page.assertIntegrity();
        for (0..page.size.rows) |y| {
            const row = page.getRow(y);
            if (!row.hyperlink) continue;
            for (page.getCells(row)) |*cell| {
                if (!cell.hyperlink) continue;
                try testing.expect(page.lookupHyperlink(cell) != null);
            }
        }
    }
    {
        const last_page: *Page = s.pages.pages.last.?.page();
        try testing.expectEqual(
            @as(usize, s.pages.cols),
            last_page.hyperlink_set.count(),
        );
    }
}

test "Screen: clear above cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 3 });
    defer s.deinit();
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    s.clearRows(
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = s.cursor.y - 1 } },
        false,
    );
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("\n\n6IJKL", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("\n\n6IJKL", contents);
    }

    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}

test "Screen: clear above cursor with history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    s.clearRows(
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = s.cursor.y - 1 } },
        false,
    );
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("\n\n6IJKL", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL\n\n\n6IJKL", contents);
    }

    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}

test "Screen: cursorSetHyperlink OOM + URI too large for string alloc" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Start a hyperlink with a URI that just barely fits in the string alloc.
    // This will ensure that additional string alloc space is needed for the
    // redundant copy of the URI when the page is re-alloced.
    const uri = "a" ** (pagepkg.std_capacity.string_bytes - 8);
    try s.startHyperlink(uri, null);

    // Figure out how many cells should can have hyperlinks in this page,
    // and write twice that number, to guarantee the capacity needs to be
    // increased at some point.
    const base_capacity = s.cursor.page_pin.node.page().hyperlinkCapacity();
    const base_string_bytes = s.cursor.page_pin.node.capacity().string_bytes;
    for (0..base_capacity * 2) |_| {
        try s.cursorSetHyperlink();
        if (s.cursor.x >= s.pages.cols - 1) {
            try cursorDownOrScroll(&s);
            s.cursorHorizontalAbsolute(0);
        } else {
            s.cursorRight(1);
        }
    }

    // Make sure the capacity really did increase.
    try testing.expect(base_capacity < s.cursor.page_pin.node.page().hyperlinkCapacity());
    // And that our string_bytes increased as well.
    try testing.expect(base_string_bytes < s.cursor.page_pin.node.capacity().string_bytes);
}

test "Screen: cursorScrollRegionUp recycled row has default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4MNOP\n5QRST");

    // Simulate the top region row being part of a soft-wrapped,
    // prompt-marked line. Its Row storage is recycled as the new
    // blank cursor row and must not retain the metadata.
    {
        const rac = s.pages.getCell(.{ .active = .{} }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }

    s.cursorAbsolute(1, 2);
    try s.cursorScrollRegionUp(2);

    {
        const rac = s.pages.getCell(.{ .active = .{ .y = 2 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n\n4MNOP\n5QRST", contents);
    }
}

test "Screen: cursorScrollRegionUp cross-page recycled row has default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();

    // We need to get the active area to span two pages so that the
    // scroll region does too, exercising the slow path (eraseRowBounded).
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");

    // The first row of the last page is the Row storage that ends up
    // recycled as the blank region-bottom row: the erased row's
    // storage stays on the first page (receiving this row's content
    // via clone) while this storage is cleared for the blank row.
    {
        const rac = s.pages.getCell(.{ .active = .{ .y = 3 } }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }

    // Region rows 1-3 with the cursor on the region bottom, which is
    // on the second page while the region top is on the first page.
    s.cursorAbsolute(0, 3);
    try s.cursorScrollRegionUp(2);

    {
        const rac = s.pages.getCell(.{ .active = .{ .y = 3 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1A\n3C\n4D\n\n5E", contents);
    }
}

test "Screen: cursorScrollAbove cross-page recycled row has default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();

    // Get the cursor page and the last page to differ so that
    // cursorScrollAbove takes the cross-page rotate path.
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");
    s.cursorAbsolute(0, 1);
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try testing.expect(s.pages.pages.first.?.next != null);

    // The last row of the cursor page is the Row storage that gets
    // recycled as the new blank row below the cursor after its content
    // is moved down to the next page.
    {
        const rac = s.pages.getCell(.{ .active = .{ .y = 2 } }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }

    try s.cursorScrollAbove();

    // One row scrolled into history, so the blank row is at active
    // y=1 (just below the cursor's original row).
    {
        const rac = s.pages.getCell(.{ .active = .{ .y = 1 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2B\n\n3C\n4D\n5E", contents);
    }
}

test "Screen: cursorDownScroll no scrollback recycled row has default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    {
        const rac = s.pages.getCell(.{ .active = .{} }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }

    s.cursorAbsolute(0, 2);
    try s.cursorDownScroll();

    {
        const rac = s.pages.getCell(.{ .active = .{ .y = 2 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}

test "Screen: cursorDownScroll single row no scrollback resets metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 1, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD");

    {
        const rac = s.pages.getCell(.{ .active = .{} }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }

    try s.cursorDownScroll();

    {
        const rac = s.pages.getCell(.{ .active = .{} }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}
