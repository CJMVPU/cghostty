//! Screen operations regression tests.
const support = @import("support.zig");
const Screen = support.Screen;
const std = support.std;
const style = support.style;
const init = support.init;

test "Screen read and write" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    try testing.expectEqual(@as(style.Id, 0), s.cursor.style_id);

    try s.testWriteString("hello, world");
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("hello, world", str);
}

test "Screen read and write newline" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    try testing.expectEqual(@as(style.Id, 0), s.cursor.style_id);

    try s.testWriteString("hello\nworld");
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("hello\nworld", str);
}

test "Screen clearRows active one line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();

    try s.testWriteString("hello, world");
    s.clearRows(.{ .active = .{} }, null, false);
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}

test "Screen clearRows active multi line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();

    try s.testWriteString("hello\nworld");
    s.clearRows(.{ .active = .{} }, null, false);
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}

test "Screen clearCells empty range" {
    const testing = std.testing;

    var s = try Screen.init(testing.io, testing.allocator, .default);
    defer s.deinit();

    const page = s.cursor.page_pin.node.page();
    const row = s.cursor.page_row;
    const cells = page.getCells(row);
    s.clearCells(page, row, cells[0..0]);
}

test "Screen clearRows uses stored page width" {
    const testing = std.testing;

    var s = try Screen.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();

    try s.testWriteString("AB");
    const node = s.pages.pages.first.?;
    s.pages.cols = 4;

    s.clearRows(.{ .screen = .{} }, null, false);
    const cells = node.page().getCells(&node.page().rows.ptr(node.page().memory)[0]);
    try testing.expectEqual(@as(usize, 2), cells.len);
    for (cells) |cell| try testing.expect(cell.isEmpty());
}

test "Screen eraseRows history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 1000 });
    defer s.deinit();

    try s.testWriteString("1\n2\n3\n4\n5\n6");

    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("1\n2\n3\n4\n5\n6", str);
    }

    s.eraseHistory(null);

    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
}

test "Screen eraseRows history with more lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 1000 });
    defer s.deinit();

    try s.testWriteString("A\nB\nC\n1\n2\n3\n4\n5\n6");

    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("A\nB\nC\n1\n2\n3\n4\n5\n6", str);
    }

    s.eraseHistory(null);

    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
}

test "Screen eraseRows active partial" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    try s.testWriteString("1\n2\n3");

    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("1\n2\n3", str);
    }

    s.eraseActive(1);

    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("3", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("3", str);
    }
}

test "Screen: clear history with no history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.pages.viewport == .active);
    s.eraseHistory(null);
    try testing.expect(s.pages.viewport == .active);
    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}

test "Screen: clear history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.pages.viewport == .active);

    // Scroll to top
    s.scroll(.{ .top = {} });
    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    s.eraseHistory(null);
    try testing.expect(s.pages.viewport == .active);
    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}
