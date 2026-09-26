//! Screen attributes regression tests.
const support = @import("support.zig");
const Screen = support.Screen;
const std = support.std;
const size = support.size;
const style = support.style;
const init = support.init;

test "Screen style basics" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const page = s.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 0), page.styles.count());

    // Set a new style
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try testing.expect(s.cursor.style.flags.bold);

    // Set another style, we should still only have one since it was unused
    try s.setAttribute(.{ .italic = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try testing.expect(s.cursor.style.flags.italic);
}

test "Screen style reset to default" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const page = s.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 0), page.styles.count());

    // Set a new style
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count());

    // Reset to default
    try s.setAttribute(.{ .reset_bold = {} });
    try testing.expect(s.cursor.style_id == 0);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}

test "Screen style reset with unset" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const page = s.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 0), page.styles.count());

    // Set a new style
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count());

    // Reset to default
    try s.setAttribute(.{ .unset = {} });
    try testing.expect(s.cursor.style_id == 0);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}

test "Screen clearRows active styled line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();

    try s.setAttribute(.{ .bold = {} });
    try s.testWriteString("hello world");
    try s.setAttribute(.{ .unset = {} });

    // We should have one style
    const page = s.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.styles.count());

    s.clearRows(.{ .active = .{} }, null, false);

    // We should have none because active cleared it
    try testing.expectEqual(@as(usize, 0), page.styles.count());

    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}

test "Screen clearRows protected" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();

    try s.testWriteString("UNPROTECTED");
    s.cursor.protected = true;
    try s.testWriteString("PROTECTED");
    s.cursor.protected = false;
    try s.testWriteString("UNPROTECTED");
    try s.testWriteString("\n");
    s.cursor.protected = true;
    try s.testWriteString("PROTECTED");
    s.cursor.protected = false;
    try s.testWriteString("UNPROTECTED");
    s.cursor.protected = true;
    try s.testWriteString("PROTECTED");
    s.cursor.protected = false;

    s.clearRows(.{ .active = .{} }, null, true);

    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("           PROTECTED\nPROTECTED           PROTECTED", str);
}

test "Screen: hyperlink start/end" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try testing.expect(s.cursor.hyperlink_id == 0);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(0, page.hyperlink_set.count());
    }

    try s.startHyperlink("http://example.com", null);
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

test "Screen: hyperlink accepts its current values" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    try s.startHyperlink("http://example.com", "current");
    const current = s.cursor.hyperlink.?;
    try s.startHyperlink(current.uri, current.id.explicit);

    try testing.expectEqualStrings("http://example.com", s.cursor.hyperlink.?.uri);
    try testing.expectEqualStrings("current", s.cursor.hyperlink.?.id.explicit);
}

test "Screen: implicit hyperlink ID wraps" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    s.cursor.hyperlink_implicit_id = std.math.maxInt(size.OffsetInt);
    try s.startHyperlink("http://example.com", null);

    try testing.expectEqual(@as(size.OffsetInt, 0), s.cursor.hyperlink_implicit_id);
    try testing.expectEqual(
        std.math.maxInt(size.OffsetInt),
        s.cursor.hyperlink.?.id.implicit,
    );

    // A failed allocation must roll the wrapped counter back to its
    // original value as well.
    s.endHyperlink();
    s.cursor.hyperlink_implicit_id = std.math.maxInt(size.OffsetInt);
    var failing = testing.FailingAllocator.init(alloc, .{});
    failing.fail_index = failing.alloc_index;
    {
        const original_alloc = s.alloc;
        defer s.alloc = original_alloc;
        s.alloc = failing.allocator();
        try testing.expectError(
            error.OutOfMemory,
            s.startHyperlink("http://example.com", null),
        );
    }
    try testing.expectEqual(
        std.math.maxInt(size.OffsetInt),
        s.cursor.hyperlink_implicit_id,
    );
}

test "Screen: hyperlink reuse" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    try testing.expect(s.cursor.hyperlink_id == 0);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(0, page.hyperlink_set.count());
    }

    // Use it for the first time
    try s.startHyperlink("http://example.com", null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    const id = s.cursor.hyperlink_id;

    // Reuse the same hyperlink, expect we have the same ID
    try s.startHyperlink("http://example.com", null);
    try testing.expectEqual(id, s.cursor.hyperlink_id);
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

test "Screen setAttribute splits page on OutOfSpace at max styles" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();

    // Write content to multiple rows so we have something to split
    try s.testWriteString("line1\nline2\nline3\nline4\nline5");

    // Remember the original node
    const original_node = s.cursor.page_pin.node;

    // Increase the page's style capacity to max by repeatedly calling increaseCapacity
    // Use Screen.increaseCapacity to properly maintain cursor state
    const max_styles = std.math.maxInt(size.CellCountInt);
    while (s.cursor.page_pin.node.capacity().styles < max_styles) {
        _ = s.increaseCapacity(
            s.cursor.page_pin.node,
            .styles,
        ) catch break;
    }

    // Get the page reference after increaseCapacity - cursor may have moved
    var page = s.cursor.page_pin.node.page();
    try testing.expectEqual(max_styles, page.capacity.styles);

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

    // Track the node before setAttribute
    const node_before_set = s.cursor.page_pin.node;

    // Now try to set a new unique attribute that would require a new style slot
    // At max capacity, increaseCapacity will return OutOfSpace, triggering page split
    try s.setAttribute(.bold);

    // The style should have been applied (bold flag set)
    try testing.expect(s.cursor.style.flags.bold);

    // The cursor should have a valid non-default style_id
    try testing.expect(s.cursor.style_id != style.default_id);

    // The page should have been split
    const page_was_split = s.cursor.page_pin.node != node_before_set or
        node_before_set.next != null or
        node_before_set.prev != null or
        s.cursor.page_pin.node != original_node;
    try testing.expect(page_was_split);
}
