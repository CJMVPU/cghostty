//! Screen selection regression tests.
const support = @import("support.zig");
const Screen = support.Screen;
const std = support.std;
const Selection = support.Selection;
const point = support.point;
const size = support.size;
const Cell = support.Cell;
const Pin = support.Pin;
const init = support.init;
const selectWord = support.selectWord;
const PromptClickMove = support.PromptClickMove;

test "Screen: scrolling moves selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Select a single line
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
        false,
    ));

    // Scroll down, should still be bottom
    try s.cursorDownScroll();

    // Our selection should've moved up
    {
        const sel = s.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s.pages.cols - 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom does nothing
    s.scroll(.{ .active = {} });

    // Our selection should've stayed the same
    {
        const sel = s.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s.pages.cols - 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scroll up again
    try s.cursorDownScroll();

    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL", contents);
    }

    // Our selection should be null because it left the screen.
    {
        const sel = s.selection.?;
        try testing.expect(s.pages.pointFromPin(.active, sel.start()) == null);
        try testing.expect(s.pages.pointFromPin(.active, sel.end()) == null);
    }
}

test "Screen: cursorScrollRegionUp moves selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4MNOP\n5QRST");

    // Select the second row.
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
        false,
    ));

    s.cursorAbsolute(0, 2);
    try s.cursorScrollRegionUp(2);

    // Our selection should've moved up with its row.
    {
        const sel = s.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s.pages.cols - 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n\n4MNOP\n5QRST", contents);
    }
}

test "Screen: clone contains full selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Select a single line
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
        false,
    ));

    // Clone
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{} },
        null,
    );
    defer s2.deinit();

    // Our selection should remain valid
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 1,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: clone contains none of selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Select a single line
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 0 } }).?,
        false,
    ));

    // Clone
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 1 } },
        null,
    );
    defer s2.deinit();

    // Our selection should be null
    try testing.expect(s2.selection == null);
}

test "Screen: clone contains selection start cutoff" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Select a single line
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
        false,
    ));

    // Clone
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 1 } },
        null,
    );
    defer s2.deinit();

    // Our selection should remain valid
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 0,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: clone contains selection end cutoff" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Select a single line
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        s.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
        false,
    ));

    // Clone
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = 1 } },
    );
    defer s2.deinit();

    // Our selection should remain valid
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 2,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: clone contains selection end cutoff reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Select a single line
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        false,
    ));

    // Clone
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = 1 } },
    );
    defer s2.deinit();

    // Our selection should remain valid
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 2,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: clone contains subset of selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 4, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    // Select the full screen
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 0, .y = 3 } }).?,
        false,
    ));

    // Clone
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 1 } },
        .{ .active = .{ .y = 2 } },
    );
    defer s2.deinit();

    // Our selection should remain valid
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 3,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: clone clamps clipped selections to mixed-width pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 4, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();

    const first = s.pages.pages.first.?;
    try s.pages.split(.{ .node = first, .y = 2 });
    try s.pages.split(.{ .node = first, .y = 1 });
    const middle = first.next.?;
    const last = middle.next.?;
    middle.page().size.cols = 2;

    try s.select(Selection.init(
        .{ .node = first },
        .{ .node = last, .x = 3 },
        false,
    ));
    var linear = try s.clone(
        io,
        alloc,
        .{ .screen = .{} },
        .{ .screen = .{ .y = 1 } },
    );
    defer linear.deinit();
    const linear_end = linear.selection.?.end();
    _ = linear_end.rowAndCell();
    try testing.expectEqual(@as(size.CellCountInt, 1), linear_end.x);

    try s.select(Selection.init(
        .{ .node = first, .x = 3 },
        .{ .node = last, .x = 3 },
        true,
    ));
    var rectangle = try s.clone(
        io,
        alloc,
        .{ .screen = .{ .y = 1 } },
        null,
    );
    defer rectangle.deinit();
    const rectangle_start = rectangle.selection.?.start();
    _ = rectangle_start.rowAndCell();
    try testing.expectEqual(@as(size.CellCountInt, 1), rectangle_start.x);
}

test "Screen: clone contains subset of rectangle selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 4, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    // Select the full screen from x=1 to x=3
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 3, .y = 3 } }).?,
        true,
    ));

    // Clone
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 1 } },
        .{ .active = .{ .y = 2 } },
    );
    defer s2.deinit();

    // Our selection should remain valid and be properly clipped
    // preserving the columns of the start and end points of the
    // selection.
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 3,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: select untracked" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");

    try testing.expect(s.selection == null);
    const tracked = s.pages.countTrackedPins();
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
        false,
    ));
    try testing.expectEqual(tracked + 2, s.pages.countTrackedPins());
    try s.select(null);
    try testing.expectEqual(tracked, s.pages.countTrackedPins());
}

test "Screen: select replaces existing pins" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");

    const tracked = s.pages.countTrackedPins();
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
        false,
    ));
    try testing.expectEqual(tracked + 2, s.pages.countTrackedPins());

    // Replacing the selection must untrack the prior selection's pins
    // rather than leak them.
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        s.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?,
        false,
    ));
    try testing.expectEqual(tracked + 2, s.pages.countTrackedPins());
}

test "Screen: reselecting tracked selection preserves its pins" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();

    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
        false,
    ));

    try s.select(s.selection.?);
    try testing.expectEqual(Selection.Order.forward, s.selection.?.order(&s));
}

test "Screen: selectAll" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();

    {
        try s.testWriteString("ABC  DEF\n 123\n456");
        var sel = s.selectAll().?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    {
        try s.testWriteString("\nFOO\n BAR\n BAZ\n QWERTY\n 12345678");
        var sel = s.selectAll().?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 8,
            .y = 7,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Screen: selectLine" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");

    // Outside of active area
    // try testing.expect(s.selectLine(.{ .x = 13, .y = 0 }) == null);
    // try testing.expect(s.selectLine(.{ .x = 0, .y = 5 }) == null);

    // Going forward
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going backward
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 7,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going forward and backward
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Outside active area
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 9,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Screen: selectLine across soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString(" 12 34012   \n 123");

    // Going forward
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Screen: selectLine across full soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD2EFGH\n3IJKL");

    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Screen: selectLine across soft-wrap ignores blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString(" 12 34012             \n 123");

    // Going forward
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going backward
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going forward and backward
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Screen: selectLine disabled whitespace trimming" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString(" 12 34012   \n 123");

    // Going forward
    {
        var sel = s.selectLine(.{
            .pin = s.pages.pin(.{ .active = .{
                .x = 1,
                .y = 0,
            } }).?,
            .whitespace = null,
        }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Non-wrapped
    {
        var sel = s.selectLine(.{
            .pin = s.pages.pin(.{ .active = .{
                .x = 1,
                .y = 3,
            } }).?,
            .whitespace = null,
        }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Screen: selectLine with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 2, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");

    // Selecting first line
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    // Selecting last line
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 2,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
}

// https://github.com/mitchellh/ghostty/issues/1329
test "Screen: selectLine semantic prompt boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ABCDE\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("A    ");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("> ");

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("ABCDE\nA    \n> ", contents);
    }

    // Selecting output stops at the prompt even if soft-wrapped
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        const expected = "A";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 2,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: selectLine semantic prompt to input boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Write prompt followed by user input on same row: "$>command"
    // Using non-whitespace to avoid whitespace trimming affecting the test
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$>");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("command");

    // Selecting from prompt should only select prompt
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    // Selecting from input should only select input
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 5,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 8,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: selectLine semantic input to output boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Row 0: user input
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("ls -la\n");
    // Row 1: command output
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("file.txt");

    // Selecting from input should only select input
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("ls -la", contents);
    }

    // Selecting from output should only select output
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("file.txt", contents);
    }
}

test "Screen: selectLine semantic mid-row boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Single row with output then prompt then input: "out$>cmd"
    // Using non-whitespace to avoid whitespace trimming affecting the test
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("out");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$>");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("cmd");

    // Selecting from output should stop at prompt
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    // Selecting from prompt should only select prompt
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 4,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    // Selecting from input should only select input
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 6,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 5,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: selectLine semantic boundary soft-wrap with mid-row transition" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Row 0: prompt "$ " + input "cmd" (soft-wraps)
    // Row 1: input continues "12" + output "out"
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$ ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("cmd12");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("out");

    // Verify layout
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("$ cmd\n12out", contents);
    }

    // Selecting from input on row 0 should get all input across soft-wrap
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("cmd12", contents);
    }

    // Selecting from input on row 1 should get all input across soft-wrap
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("cmd12", contents);
    }

    // Selecting from output should only get output
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("out", contents);
    }
}

test "Screen: selectLine semantic boundary disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Write prompt followed by input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$ ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("command");

    // With semantic_prompt_boundary = false, should select entire line
    {
        var sel = s.selectLine(.{
            .pin = s.pages.pin(.{ .active = .{
                .x = 0,
                .y = 0,
            } }).?,
            .semantic_prompt_boundary = false,
        }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("$ command", contents);
    }
}

test "Screen: selectLine semantic boundary first cell of row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Row 0: input that soft-wraps
    // Row 1: output starts at first cell
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("12345");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("ABCDE");

    // Verify soft-wrap happened
    {
        const pin = s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = pin.rowAndCell().row;
        try testing.expect(row.wrap);
    }

    // Selecting from input should stop before output on row 1
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 4,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    // Selecting from output should only get output
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: selectLine semantic boundary across mixed-width pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 4, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();

    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("ABCD");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("E");

    const first = s.pages.pages.first.?;
    try s.pages.split(.{ .node = first, .y = 1 });
    const second = first.next.?;
    first.page().size.cols = 2;
    s.pages.pauseIntegrityChecks(true);
    defer s.pages.pauseIntegrityChecks(false);

    try testing.expectEqual(@as(size.CellCountInt, 2), first.cols());
    try testing.expectEqual(@as(size.CellCountInt, 4), second.cols());

    var sel = s.selectLine(.{ .pin = .{
        .node = first,
        .x = 1,
    } }).?;
    defer sel.deinit(&s);
    try testing.expect((Pin{ .node = first, .x = 0 }).eql(sel.start()));
    try testing.expect((Pin{ .node = first, .x = 1 }).eql(sel.end()));
}

test "Screen: selectLine semantic all same content" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // All prompt content that soft-wraps
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("prompt text");

    // Verify soft-wrap
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("promp\nt tex\nt", contents);
    }

    // Should select all prompt content across soft-wraps
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("prompt text", contents);
    }
}

test "Screen: selectWord" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");

    // Default boundary codepoints for word selection
    const boundary_codepoints = &[_]u21{
        0,   ' ', '\t', '\'', '"',
        '│',
        '`', '|', ':',  ';',  ',',
        '(', ')', '[',  ']',  '{',
        '}', '<', '>',  '$',
    };

    // Outside of active area
    // try testing.expect(s.selectWord(.{ .x = 9, .y = 0 }) == null);
    // try testing.expect(s.selectWord(.{ .x = 0, .y = 5 }) == null);

    // Going forward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going backward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going forward and backward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Whitespace
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Whitespace single char
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // End of screen
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 2,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Screen: selectWord across soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString(" 1234012\n 123");

    // Default boundary codepoints for word selection
    const boundary_codepoints = &[_]u21{
        0,   ' ', '\t', '\'', '"',
        '│',
        '`', '|', ':',  ';',  ',',
        '(', ')', '[',  ']',  '{',
        '}', '<', '>',  '$',
    };

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(" 1234\n012\n 123", contents);
    }

    // Going forward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going backward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going forward and backward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Screen: selectWord whitespace across soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1       1\n 123");

    // Default boundary codepoints for word selection
    const boundary_codepoints = &[_]u21{
        0,   ' ', '\t', '\'', '"',
        '│',
        '`', '|', ':',  ';',  ',',
        '(', ')', '[',  ']',  '{',
        '}', '<', '>',  '$',
    };

    // Going forward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going backward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going forward and backward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Screen: selectWord with character boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // Default boundary codepoints for word selection
    const boundary_codepoints = &[_]u21{
        0,   ' ', '\t', '\'', '"',
        '│',
        '`', '|', ':',  ';',  ',',
        '(', ')', '[',  ']',  '{',
        '}', '<', '>',  '$',
    };

    const cases = [_][]const u8{
        " 'abc' \n123",
        " \"abc\" \n123",
        " │abc│ \n123",
        " `abc` \n123",
        " |abc| \n123",
        " :abc: \n123",
        " ;abc; \n123",
        " ,abc, \n123",
        " (abc( \n123",
        " )abc) \n123",
        " [abc[ \n123",
        " ]abc] \n123",
        " {abc{ \n123",
        " }abc} \n123",
        " <abc< \n123",
        " >abc> \n123",
        " $abc$ \n123",
    };

    for (cases) |case| {
        var s = try init(io, alloc, .{ .cols = 20, .rows = 10, .max_scrollback_bytes = 0 });
        defer s.deinit();
        try s.testWriteString(case);

        // Inside character forward
        {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = 2,
                .y = 0,
            } }).?, boundary_codepoints).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 2,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
        }

        // Inside character backward
        {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = 4,
                .y = 0,
            } }).?, boundary_codepoints).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 2,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
        }

        // Inside character bidirectional
        {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = 3,
                .y = 0,
            } }).?, boundary_codepoints).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 2,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
        }

        // On quote
        // NOTE: this behavior is not ideal, so we can change this one day,
        // but I think its also not that important compared to the above.
        {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = 1,
                .y = 0,
            } }).?, boundary_codepoints).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 0,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 1,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
        }
    }
}

test "Screen: selectOutput" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 15, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Build content with cell-level semantic content:
    // Row 0-1: output1 (output)
    // Row 2: prompt2 (prompt)
    // Row 3: input2 (input)
    // Row 4-7: output2 (output, with overflow causing wrap)
    // Row 8: "$ " (prompt) + "input3" (input)
    // Row 9-11: output3 (output)
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("output1\n");
    try s.testWriteString("output1\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("prompt2\n");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("input2\n");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("output2output2output2output2\n");
    try s.testWriteString("output2\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$ ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("input3\n");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("output3\n");
    try s.testWriteString("output3\n");
    try s.testWriteString("output3");

    // First output block (rows 0-1), should select those rows
    {
        var sel = s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).?).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("output1\noutput1", contents);
    }
    // Second output block (rows 4-7)
    {
        var sel = s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 7,
        } }).?).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings(
            "output2output2output2output2\noutput2",
            contents,
        );
    }
    // Third output block (rows 9-11)
    {
        var sel = s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 10,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 9,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 6,
            .y = 11,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    // Click on prompt should return null
    {
        try testing.expect(s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 8,
        } }).?) == null);
    }
    // Click on input should return null
    {
        try testing.expect(s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 5,
            .y = 8,
        } }).?) == null);
    }
}

test "Screen: selectionString basic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString start outside of written area" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString end outside of written area" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString trim space" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1AB  \n2EFGH\n3IJKL";
    try s.testWriteString(str);

    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
        false,
    );

    {
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "1AB\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }

    // No trim
    {
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        const expected = "1AB  \n2EF";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString trim empty line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1AB  \n\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
        false,
    );

    {
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "1AB\n\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }

    // No trim
    {
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        const expected = "1AB  \n\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "2EFGH3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1A⚡";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "⚡";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString wide char with header" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABC⚡";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }
}

// https://github.com/mitchellh/ghostty/issues/289
test "Screen: selectionString empty with soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Let me describe the situation that caused this because this
    // test is not obvious. By writing an emoji below, we introduce
    // one cell with the emoji and one cell as a "wide char spacer".
    // We then soft wrap the line by writing spaces.
    //
    // By selecting only the tail, we'd select nothing and we had
    // a logic error that would cause a crash.
    try s.testWriteString("👨");
    try s.testWriteString("      ");

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "👨";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString with zero width joiner" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 1, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "👨‍"; // this has a ZWJ
    try s.testWriteString(str);

    // Integrity check
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 0, .x = 0 } }).?;
        const cell = pin.rowAndCell().cell;
        try testing.expectEqual(@as(u21, 0x1F468), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = pin.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }

    // The real test
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "👨‍";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString, rectangle, basic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 30, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str =
        \\Lorem ipsum dolor
        \\sit amet, consectetur
        \\adipiscing elit, sed do
        \\eiusmod tempor incididunt
        \\ut labore et dolore
    ;
    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 6, .y = 3 } }).?,
        true,
    );
    const expected =
        \\t ame
        \\ipisc
        \\usmod
    ;
    try s.testWriteString(str);

    const contents = try s.selectionString(alloc, .{
        .sel = sel,
        .trim = true,
    });
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}

test "Screen: selectionString, rectangle, w/EOL" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 30, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str =
        \\Lorem ipsum dolor
        \\sit amet, consectetur
        \\adipiscing elit, sed do
        \\eiusmod tempor incididunt
        \\ut labore et dolore
    ;
    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 12, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 26, .y = 4 } }).?,
        true,
    );
    const expected =
        \\dolor
        \\nsectetur
        \\lit, sed do
        \\or incididunt
        \\ dolore
    ;
    try s.testWriteString(str);

    const contents = try s.selectionString(alloc, .{
        .sel = sel,
        .trim = true,
    });
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}

test "Screen: selectionString, rectangle, more complex w/breaks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 30, .rows = 8, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str =
        \\Lorem ipsum dolor
        \\sit amet, consectetur
        \\adipiscing elit, sed do
        \\eiusmod tempor incididunt
        \\ut labore et dolore
        \\
        \\magna aliqua. Ut enim
        \\ad minim veniam, quis
    ;
    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 11, .y = 2 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 26, .y = 7 } }).?,
        true,
    );
    const expected =
        \\elit, sed do
        \\por incididunt
        \\t dolore
        \\
        \\a. Ut enim
        \\niam, quis
    ;
    try s.testWriteString(str);

    const contents = try s.selectionString(alloc, .{
        .sel = sel,
        .trim = true,
    });
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}

test "Screen: selectionString multi-page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 2048 });
    defer s.deinit();

    const first_page_size = s.pages.pages.first.?.capacity().rows;

    // Lazy way to seek to the first page boundary.
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 1) |_| {
        try s.testWriteString("\n");
    }
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);

    try s.testWriteString("123456789\n!@#$%^&*(\n123456789");

    {
        const sel = Selection.init(
            s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "123456789\n!@#$%^&*(\n123";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: lineIterator" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH";
    try s.testWriteString(str);

    // Test the line iterator
    var iter = s.lineIterator(s.pages.pin(.{ .viewport = .{} }).?);
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(actual);
        try testing.expectEqualStrings("1ABCD", actual);
    }
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(actual);
        try testing.expectEqualStrings("2EFGH", actual);
    }
}

test "Screen: lineIterator soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH\n3ABCD";
    try s.testWriteString(str);

    // Test the line iterator
    var iter = s.lineIterator(s.pages.pin(.{ .viewport = .{} }).?);
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(actual);
        try testing.expectEqualStrings("1ABCD2EFGH", actual);
    }
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(actual);
        try testing.expectEqualStrings("3ABCD", actual);
    }
    // try testing.expect(iter.next() == null);
}

test "Screen: promptClickMove line right basic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Move cursor back to start of input (column 2, the 'h')
    s.cursorAbsolute(2, 0);

    // Click on first 'l' (column 4), should require 2 right movements (h->e->l)
    const click_pin = s.pages.pin(.{ .active = .{ .x = 4, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 2), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove line right cursor not on input" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    s.cursorSetSemanticContent(.output);

    // Move cursor back to prompt area (column 0, the '>')
    s.cursorAbsolute(0, 0);

    // Cursor is on prompt, not input - should return zero
    const click_pin = s.pages.pin(.{ .active = .{ .x = 4, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(PromptClickMove.zero, result);
}

test "Screen: promptClickMove line right click on same position" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Move cursor to column 4
    s.cursorAbsolute(4, 0);

    // Click on same position - no movement needed
    const click_pin = s.pages.pin(.{ .active = .{ .x = 4, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(PromptClickMove.zero, result);
}

test "Screen: promptClickMove line right skips non-input cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write: "> h" then output "X" then input "llo"
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("h");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("X");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("llo");

    // Move cursor to column 2 (the 'h')
    s.cursorAbsolute(2, 0);

    // Click on 'l' at column 5 - should skip the 'X' output cell
    // Movement: h (start) -> l (col 4) -> l (col 5) = 2 right movements
    const click_pin = s.pages.pin(.{ .active = .{ .x = 5, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 2), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove line right soft-wrapped line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input that wraps
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    // Write 8 chars of input, first row has 2 for prompt + 8 input = 10 cols
    try s.testWriteString("abcdefgh");
    // Continue on next row (soft-wrapped)
    try s.testWriteString("ij");

    // Verify soft wrap occurred
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("> abcdefgh\nij", contents);
    }

    // Move cursor to column 2 (the 'a')
    s.cursorAbsolute(2, 0);

    // Click on 'j' at column 1, row 1 - should count all input cells
    // Movement: a->b->c->d->e->f->g->h->i->j = 9 right movements
    const click_pin = s.pages.pin(.{ .active = .{ .x = 1, .y = 1 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 9), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove disabled when click is none" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Click mode is .none by default (disabled)
    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick.none, s.semantic_prompt.click);

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Move cursor to start of input
    s.cursorAbsolute(2, 0);

    // Click should return zero since click mode is disabled
    const click_pin = s.pages.pin(.{ .active = .{ .x = 4, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(PromptClickMove.zero, result);
}

test "Screen: promptClickMove line right stops at hard wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write prompt and input on first line
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    // Hard wrap (newline)
    try s.testWriteString("\n");
    try s.testWriteString("world");

    // Move cursor to column 2 (the 'h')
    s.cursorAbsolute(2, 0);

    // Click on 'w' at column 0, row 1 - but line mode stops at hard wrap
    // Should only move to end of first line: h->e->l->l->o = 4 movements
    const click_pin = s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?;
    const result = s.promptClickMove(click_pin);

    // Should stop at end of first line, not cross hard wrap
    try testing.expectEqual(@as(usize, 5), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove line right stops at non-continuation row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Row 0: PROMPT "> hello"
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello\n");

    // Row 1: CONTINUATION "world"
    s.cursorSetSemanticContent(.{ .prompt = .continuation });
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("world\n");

    // Row 2: NEW PROMPT "> again"
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("again");

    // Verify content
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("> hello\nworld\n> again", contents);
    }

    // Move cursor to 'w' at column 0, row 1
    s.cursorAbsolute(0, 1);

    // Click on 'a' at column 2, row 2 - but row 2 is a new prompt
    // Should stop at end of "world": w->o->r->l->d = 4 movements
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?;
    const result = s.promptClickMove(click_pin);

    // Should stop at 'd' (end of world), not cross to new prompt
    try testing.expectEqual(@as(usize, 5), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove line left basic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Cursor is at column 7 (after 'o'), move it to column 6 (the 'o')
    s.cursorAbsolute(6, 0);

    // Click on 'h' (column 2), should require 4 left movements (o->l->l->e->h)
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 4), result.left);
    try testing.expectEqual(@as(usize, 0), result.right);
}

test "Screen: promptClickMove line left skips non-input cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write: "> h" then output "X" then input "llo"
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("h");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("X");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("llo");

    // Move cursor to column 6 (the 'o')
    s.cursorAbsolute(6, 0);

    // Click on 'h' at column 2 - should skip the 'X' output cell
    // Movement: o->l->l->h = 3 left movements (skipping X)
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 3), result.left);
    try testing.expectEqual(@as(usize, 0), result.right);
}

test "Screen: promptClickMove line left soft-wrapped line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input that wraps
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    // Write 8 chars of input, first row has 2 for prompt + 8 input = 10 cols
    try s.testWriteString("abcdefgh");
    // Continue on next row (soft-wrapped)
    try s.testWriteString("ij");

    // Verify soft wrap occurred
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("> abcdefgh\nij", contents);
    }

    // Cursor is at column 2, row 1 (after 'j'). Move to 'j' at column 1.
    s.cursorAbsolute(1, 1);

    // Click on 'a' at column 2, row 0 - should count all input cells backwards
    // Movement: j->i->h->g->f->e->d->c->b->a = 9 left movements
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 9), result.left);
    try testing.expectEqual(@as(usize, 0), result.right);
}

test "Screen: promptClickMove line left stops at hard wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write prompt and input on first line, then hard wrap
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    // Hard wrap (newline)
    try s.testWriteString("\n");
    try s.testWriteString("world");

    // Move cursor to 'd' at column 4, row 1 (an actual input cell)
    s.cursorAbsolute(4, 1);

    // Click on 'h' at column 2, row 0 - but line mode stops at hard wrap
    // Should only move to start of second line, not cross to row 0
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    // Should stop at start of second line: d->l->r->o->w = 4 movements
    try testing.expectEqual(@as(usize, 4), result.left);
    try testing.expectEqual(@as(usize, 0), result.right);
}

test "Screen: promptClickMove click right of input same line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // Set up: "> hello" where "> " is prompt and "hello" is input
    // Clicking to the right of the 'o' should move cursor past the input

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Move cursor to start of input (column 2, the 'h')
    s.cursorAbsolute(2, 0);

    // Click beyond the input (column 15) - should move to one past the 'o'
    const click_pin = s.pages.pin(.{ .active = .{ .x = 15, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 5), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove click right of input cursor at end" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Cursor is already at column 7 (one past 'o') after writing
    // Click beyond the input (column 15) - no movement needed since
    // cursor is already at the end position
    const click_pin = s.pages.pin(.{ .active = .{ .x = 15, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 0), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove click right of input on lower line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Move cursor to start of input (column 2, the 'h')
    s.cursorAbsolute(2, 0);

    // Click on a lower line (row 1) - should move to end of input
    // This is outside the prompt area so should clamp to end
    const click_pin = s.pages.pin(.{ .active = .{ .x = 5, .y = 1 } }).?;
    const result = s.promptClickMove(click_pin);

    // From 'h', we need to pass e, l, l, o (4 cells) + 1 past end = 5
    try testing.expectEqual(@as(usize, 5), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove click right of input cursor at end lower line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Cursor is at column 7 after writing (one past 'o')
    // Click on a lower line (row 1) - cursor already at end, no movement needed
    const click_pin = s.pages.pin(.{ .active = .{ .x = 5, .y = 1 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 0), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove click right of input cursor on last char" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Move cursor to last input char (column 6, the 'o')
    s.cursorAbsolute(6, 0);

    // Click beyond the input (column 15)
    const click_pin = s.pages.pin(.{ .active = .{ .x = 15, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 1), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: selectLine does not join lines across a recycled row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 6, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    // A soft-wrapped line across rows 0 and 1: row 0 gets wrap=true.
    try s.testWriteString("AAAAAAA");

    // Scroll a region of rows 0-2 up by one: row 0 is discarded and
    // its Row storage recycled as the blank row 2.
    s.cursorAbsolute(0, 2);
    try s.cursorScrollRegionUp(2);

    // Write unrelated single-line words on the recycled row and below.
    s.cursorAbsolute(0, 2);
    try s.testWriteString("world");
    s.cursorAbsolute(0, 3);
    try s.testWriteString("hello");

    // Selecting the line "world" must not extend into "hello": these
    // are separate hard lines. A stale wrap flag on the recycled row
    // would join them.
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 2,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("world", contents);
    }
}

test "Screen: selectWord at hard line breaks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const cases = [_]struct { cols: size.CellCountInt, text: []const u8 }{
        .{ .cols = 5, .text = "abcde\nfghij" },
        .{ .cols = 5, .text = "     \n     " },
        .{ .cols = 1, .text = "a\nb" },
        .{ .cols = 1, .text = " \n " },
    };
    for (cases) |case| {
        var s = try init(io, alloc, .{
            .cols = case.cols,
            .rows = 2,
            .max_scrollback_bytes = 0,
        });
        defer s.deinit();
        try s.testWriteString(case.text);

        for (0..2) |y| {
            for (0..case.cols) |x| {
                var sel = s.selectWord(s.pages.pin(.{ .active = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                } }).?, &.{ 0, ' ' }).?;
                defer sel.deinit(&s);
                try testing.expectEqual(point.Point{ .screen = .{
                    .x = 0,
                    .y = @intCast(y),
                } }, s.pages.pointFromPin(.screen, sel.start()).?);
                try testing.expectEqual(point.Point{ .screen = .{
                    .x = case.cols - 1,
                    .y = @intCast(y),
                } }, s.pages.pointFromPin(.screen, sel.end()).?);
            }
        }
    }
}

test "Screen: selectWord across soft-wrap at right edge" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    try s.testWriteString("abcdefghij\nklmno");

    for (0..2) |y| {
        for (0..5) |x| {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = @intCast(x),
                .y = @intCast(y),
            } }).?, &.{ 0, ' ' }).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 0,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 1,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
        }
    }
}

test "Screen: selectWord wide characters" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const cases = [_]struct {
        text: []const u8,
        cols: size.CellCountInt = 10,
        boundary_codepoints: []const u21 = &.{ 0, ' ' },
        start: usize = 0,
        end: usize,
        expected: []const u8,
    }{
        .{ .text = "日本語", .end = 5, .expected = "日本語" },
        .{ .text = "中文词", .end = 5, .expected = "中文词" },
        .{ .text = "中文词", .cols = 5, .end = 6, .expected = "中文词" },
        .{ .text = "a中\u{0301}文b", .end = 5, .expected = "a中\u{0301}文b" },
        .{ .text = "日本語", .end = 5, .expected = "日本語", .boundary_codepoints = &.{' '} },
        .{ .text = "a日b語c", .end = 6, .expected = "a日b語c" },
        .{ .text = " 日本語 ", .start = 1, .end = 6, .expected = "日本語" },
        .{ .text = "日本語", .cols = 4, .end = 5, .expected = "日本語" },
        .{ .text = "日本語", .cols = 5, .end = 6, .expected = "日本語" },
        .{ .text = "日本\n語文", .cols = 4, .end = 3, .expected = "日本" },
        .{ .text = "日本\n語文", .cols = 4, .start = 4, .end = 7, .expected = "語文" },
        .{ .text = "a語b", .boundary_codepoints = &.{ 0, '語' }, .end = 0, .expected = "a" },
        .{ .text = "a語b", .boundary_codepoints = &.{ 0, '語' }, .start = 1, .end = 2, .expected = "語" },
        .{ .text = "a語b", .boundary_codepoints = &.{ 0, '語' }, .start = 3, .end = 3, .expected = "b" },
        .{ .text = "abcd語ef", .cols = 5, .boundary_codepoints = &.{ 0, '語' }, .end = 3, .expected = "abcd" },
        .{ .text = "abcd語ef", .cols = 5, .boundary_codepoints = &.{ 0, '語' }, .start = 4, .end = 6, .expected = "語" },
        .{ .text = "abcd語ef", .cols = 5, .boundary_codepoints = &.{ 0, '語' }, .start = 7, .end = 8, .expected = "ef" },
    };

    for (cases) |case| {
        var s = try init(io, alloc, .{
            .cols = case.cols,
            .rows = 4,
            .max_scrollback_bytes = 0,
        });
        defer s.deinit();
        try s.testWriteString(case.text);

        // Selecting any cell in the word should select the whole word.
        for (case.start..case.end + 1) |offset| {
            const pin = s.pages.pin(.{ .active = .{
                .x = @intCast(offset % case.cols),
                .y = @intCast(offset / case.cols),
            } }).?;
            var sel = s.selectWord(pin, case.boundary_codepoints).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = @intCast(case.start % case.cols),
                .y = @intCast(case.start / case.cols),
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = @intCast(case.end % case.cols),
                .y = @intCast(case.end / case.cols),
            } }, s.pages.pointFromPin(.screen, sel.end()).?);

            const contents = try s.selectionString(alloc, .{ .sel = sel });
            defer alloc.free(contents);
            try testing.expectEqualStrings(case.expected, contents);
        }
    }
}

test "Screen: selectWord Chinese punctuation defaults and custom boundaries" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const defaults = &@import("../../selection_codepoints.zig").default_word_boundaries;
    const punctuation = [_]u21{ '，', '。', '；', '：', '！', '？', '、', '（', '）', '【', '】', '「', '」', '『', '』', '《', '》', '〈', '〉', '“', '”', '‘', '’', '　' };
    for (punctuation) |codepoint| {
        var s = try init(testing.io, alloc, .{ .cols = 20, .rows = 2, .max_scrollback_bytes = 0 });
        defer s.deinit();
        const delimiter = try std.fmt.allocPrint(alloc, "{u}", .{codepoint});
        defer alloc.free(delimiter);
        try s.testWriteString("你好");
        try s.testWriteString(delimiter);
        const right_start = s.cursor.x;
        try s.testWriteString("世界");
        for (0..s.cursor.x) |x| {
            const pin = s.pages.pin(.{ .active = .{ .x = @intCast(x), .y = 0 } }).?;
            var sel = s.selectWord(pin, defaults).?;
            defer sel.deinit(&s);
            const contents = try s.selectionString(alloc, .{ .sel = sel });
            defer alloc.free(contents);
            try testing.expectEqualStrings(if (x < 4) "你好" else if (x < right_start) delimiter else "世界", contents);
        }
        // An explicit custom set replaces the defaults, including punctuation.
        var custom = s.selectWord(s.pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?, &.{ 0, ' ' }).?;
        defer custom.deinit(&s);
        const contents = try s.selectionString(alloc, .{ .sel = custom });
        defer alloc.free(contents);
        const expected = try std.fmt.allocPrint(alloc, "你好{s}世界", .{delimiter});
        defer alloc.free(expected);
        try testing.expectEqualStrings(expected, contents);
    }
}
