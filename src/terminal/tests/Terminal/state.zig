//! Terminal state regression tests.
const support = @import("support.zig");
const std = support.std;
const testing = support.testing;
const size = support.size;
const style = support.style;
const Screen = support.Screen;
const init = support.init;
const resize_tw = support.resize_tw;
const isDirty = support.isDirty;

test "Terminal: resize resets synchronized output" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.modes.set(.synchronized_output, true);
    try t.resize(alloc, .{ .cols = 10, .rows = 5 });
    try testing.expect(!t.modes.get(.synchronized_output));
}

test "Terminal: resize rejects zero dimensions before mutation" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.width_px = 100;
    t.height_px = 100;
    t.flags.dirty.clear = false;

    try testing.expectError(error.InvalidValue, t.resize(alloc, .{
        .cols = 0,
        .rows = 5,
        .cell_size_px = .{ .width = 9, .height = 18 },
    }));
    try testing.expectError(error.InvalidValue, t.resize(alloc, .{
        .cols = 10,
        .rows = 0,
        .cell_size_px = .{ .width = 9, .height = 18 },
    }));

    try testing.expectEqual(@as(size.CellCountInt, 10), t.cols);
    try testing.expectEqual(@as(size.CellCountInt, 5), t.rows);
    try testing.expectEqual(@as(u32, 100), t.width_px);
    try testing.expectEqual(@as(u32, 100), t.height_px);
    try testing.expect(!t.flags.dirty.clear);
}

test "Terminal: resize preserves pixel dimensions when omitted" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.width_px = 90;
    t.height_px = 90;
    try t.resize(alloc, .{ .cols = 20, .rows = 10 });

    try testing.expectEqual(@as(u32, 90), t.width_px);
    try testing.expectEqual(@as(u32, 90), t.height_px);
}

test "Terminal: resize updates pixels without changing cell dimensions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.resize(alloc, .{
        .cols = 10,
        .rows = 5,
        .cell_size_px = .{ .width = 9, .height = 18 },
    });

    try testing.expectEqual(@as(u32, 90), t.width_px);
    try testing.expectEqual(@as(u32, 90), t.height_px);
}

test "Terminal: resize pixel dimensions saturate" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 3 });
    defer t.deinit(alloc);

    try t.resize(alloc, .{
        .cols = 2,
        .rows = 3,
        .cell_size_px = .{
            .width = std.math.maxInt(u32),
            .height = std.math.maxInt(u32),
        },
    });

    try testing.expectEqual(std.math.maxInt(u32), t.width_px);
    try testing.expectEqual(std.math.maxInt(u32), t.height_px);
}

test "Terminal: resize preserves tabstops on allocation failure" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, t.resize(alloc, .{
        .cols = 513,
        .rows = 1,
    }));

    try testing.expectEqual(@as(size.CellCountInt, 10), t.cols);
    try testing.expect(t.tabstops.get(8));
}

test "Terminal: resize failure paths preserve consistent state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;

    for ([_]resize_tw.FailPoint{
        .tabstops,
        .primary_screen,
        .alternate_screen,
    }) |tag| {
        const tw = resize_tw;
        defer tw.end(.reset) catch unreachable;

        var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
        defer t.deinit(alloc);

        try t.printString("primary");
        _ = try t.switchScreen(.alternate);
        try t.printString("alternate");
        _ = try t.switchScreen(.primary);

        t.width_px = 100;
        t.height_px = 50;
        t.modes.set(.synchronized_output, true);
        t.flags.dirty.clear = false;
        t.scrolling_region = .{
            .top = 1,
            .bottom = 2,
            .left = 1,
            .right = 8,
        };
        t.tabstops.unset(8);
        t.tabstops.set(3);

        const primary = t.screens.get(.primary).?;
        const alternate = t.screens.get(.alternate).?;
        const alternate_generation = t.screens.generation(.alternate);
        try testing.expectEqual(primary.pages.pages.first, primary.pages.pages.last);
        try testing.expectEqual(alternate.pages.pages.first, alternate.pages.pages.last);

        const before = t;
        const before_primary = primary.*;
        const before_alternate = alternate.*;
        const before_primary_page = try alloc.dupe(
            u8,
            primary.pages.pages.first.?.page().memory,
        );
        defer alloc.free(before_primary_page);
        const before_alternate_page = try alloc.dupe(
            u8,
            alternate.pages.pages.first.?.page().memory,
        );
        defer alloc.free(before_alternate_page);
        tw.errorAlways(tag, error.OutOfMemory);

        // A failure after the primary screen has resized is recovered by
        // dropping the inactive alternate and completing the resize. This
        // also proves the alternate tripwire is after the primary resize
        // rather than acting as a preflight check.
        if (tag == .alternate_screen) {
            try t.resize(alloc, .{
                .cols = 513,
                .rows = 4,
                .cell_size_px = .{ .width = 9, .height = 18 },
            });

            try testing.expectEqual(@as(size.CellCountInt, 513), t.cols);
            try testing.expectEqual(@as(size.CellCountInt, 4), t.rows);
            try testing.expectEqual(@as(u32, 4617), t.width_px);
            try testing.expectEqual(@as(u32, 72), t.height_px);
            try testing.expect(!t.modes.get(.synchronized_output));
            try testing.expect(t.flags.dirty.clear);
            try testing.expectEqual(@as(size.CellCountInt, 513), primary.pages.cols);
            try testing.expectEqual(@as(size.CellCountInt, 4), primary.pages.rows);
            try testing.expectEqual(@as(?*Screen, null), t.screens.get(.alternate));
            try testing.expectEqual(
                alternate_generation +% 1,
                t.screens.generation(.alternate),
            );
            try testing.expectEqual(.primary, t.screens.active_key);
            try testing.expectEqual(primary, t.screens.active);
            try testing.expect(t.tabstops.get(8));
            try testing.expect(!t.tabstops.get(3));

            // The alternate is recreated lazily at the terminal's new size.
            _ = try t.switchScreen(.alternate);
            const replacement = t.screens.get(.alternate).?;
            try testing.expectEqual(@as(size.CellCountInt, 513), replacement.pages.cols);
            try testing.expectEqual(@as(size.CellCountInt, 4), replacement.pages.rows);
            try testing.expect(replacement.pages.getCell(.{ .active = .{} }).?.cell.isEmpty());
            continue;
        }

        try testing.expectError(error.OutOfMemory, t.resize(alloc, .{
            .cols = 513,
            .rows = 4,
            .cell_size_px = .{ .width = 9, .height = 18 },
        }));

        try testing.expectEqual(before.width_px, t.width_px);
        try testing.expectEqual(before.height_px, t.height_px);
        try testing.expect(std.meta.eql(before.modes, t.modes));
        try testing.expectEqual(before.cols, t.cols);
        try testing.expectEqual(before.rows, t.rows);
        try testing.expectEqual(before.scrolling_region, t.scrolling_region);
        try testing.expectEqual(before.flags, t.flags);
        try testing.expect(std.meta.eql(before.tabstops, t.tabstops));
        try testing.expectEqual(before.screens.active_key, t.screens.active_key);
        try testing.expectEqual(before.screens.active, t.screens.active);

        try testing.expectEqual(before_primary.pages.cols, primary.pages.cols);
        try testing.expectEqual(before_primary.pages.rows, primary.pages.rows);
        try testing.expectEqual(
            before_primary.pages.total_rows,
            primary.pages.total_rows,
        );
        try testing.expect(std.meta.eql(before_primary.cursor, primary.cursor));
        try testing.expectEqualSlices(
            u8,
            before_primary_page,
            primary.pages.pages.first.?.page().memory,
        );

        try testing.expectEqual(before_alternate.pages.cols, alternate.pages.cols);
        try testing.expectEqual(before_alternate.pages.rows, alternate.pages.rows);
        try testing.expectEqual(
            before_alternate.pages.total_rows,
            alternate.pages.total_rows,
        );
        try testing.expect(std.meta.eql(before_alternate.cursor, alternate.cursor));
        try testing.expectEqualSlices(
            u8,
            before_alternate_page,
            alternate.pages.pages.first.?.page().memory,
        );
    }
}

test "Terminal: alternate resize failure replaces active alternate screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    const tw = resize_tw;
    defer tw.end(.reset) catch unreachable;

    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    _ = try t.switchScreen(.alternate);
    try testing.expectEqual(.alternate, t.screens.active_key);
    t.screens.active.charset.gl = .G1;
    try t.printString("alternate");
    const generation = t.screens.generation(.alternate);

    tw.errorAlways(.alternate_screen, error.OutOfMemory);
    try t.resize(alloc, .{ .cols = 20, .rows = 4 });

    const alternate = t.screens.get(.alternate).?;
    try testing.expectEqual(.alternate, t.screens.active_key);
    try testing.expectEqual(alternate, t.screens.active);
    try testing.expectEqual(@as(size.CellCountInt, 20), alternate.pages.cols);
    try testing.expectEqual(@as(size.CellCountInt, 4), alternate.pages.rows);
    try testing.expect(alternate.pages.getCell(.{ .active = .{} }).?.cell.isEmpty());
    try testing.expectEqual(.G1, alternate.charset.gl);
    try testing.expectEqual(generation +% 1, t.screens.generation(.alternate));
}

test "Terminal: alternate resize replacement failure falls back to primary" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    const tw = resize_tw;
    defer tw.end(.reset) catch unreachable;

    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    _ = try t.switchScreen(.alternate);
    tw.errorAlways(.alternate_screen, error.OutOfMemory);
    tw.errorAlways(.alternate_screen_init, error.OutOfMemory);
    try t.resize(alloc, .{ .cols = 20, .rows = 4 });

    const primary = t.screens.get(.primary).?;
    try testing.expectEqual(@as(?*Screen, null), t.screens.get(.alternate));
    try testing.expectEqual(.primary, t.screens.active_key);
    try testing.expectEqual(primary, t.screens.active);
    try testing.expectEqual(@as(size.CellCountInt, 20), primary.pages.cols);
    try testing.expectEqual(@as(size.CellCountInt, 4), primary.pages.rows);
}

test "Terminal: setPwd preserves a sentinel on allocation failure" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 1 });
    defer t.deinit(alloc);

    try t.pwd.ensureTotalCapacityPrecise(alloc, 3);
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, t.setPwd("pwd"));
    try testing.expect(t.getPwd() == null);
}

test "Terminal: setPwd accepts its current value" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 1 });
    defer t.deinit(testing.allocator);

    try t.setPwd("file:///tmp");
    try t.setPwd(t.getPwd().?);
    try testing.expectEqualStrings("file:///tmp", t.getPwd().?);
}

test "Terminal: setTitle preserves a sentinel on allocation failure" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 1 });
    defer t.deinit(alloc);

    try t.title.ensureTotalCapacityPrecise(alloc, 5);
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, t.setTitle("title"));
    try testing.expect(t.getTitle() == null);
}

test "Terminal: setTitle accepts its current value" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 1 });
    defer t.deinit(testing.allocator);

    try t.setTitle("Ghostty");
    try t.setTitle(t.getTitle().?);
    try testing.expectEqualStrings("Ghostty", t.getTitle().?);
}

test "Terminal: soft wrap with semantic prompt" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 3, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Mark our prompt.
    try t.semanticPrompt(.init(.prompt_start));
    // Should not make anything dirty on its own.
    try testing.expect(!isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));

    // Write and wrap
    for ("hello") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        try testing.expectEqual(.prompt, list_cell.row.semantic_prompt);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
}

test "Terminal: overwrite hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Setup our hyperlink and print
    try t.screens.active.startHyperlink("http://one.example.com", null);
    try t.printString("123");
    t.setCursorPos(1, 1);
    t.screens.active.endHyperlink();
    try t.printString("456");

    // Verify all our cells have a hyperlink
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const page = list_cell.node.page();
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        try testing.expect(page.lookupHyperlink(cell) == null);
        try testing.expectEqual(0, page.hyperlink_set.count());
    }

    try testing.expect(isDirty(&t, .{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: cursorPos resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.setCursorPos(1, 1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBCDE", str);
    }
}

test "Terminal: cursorPos off the screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(500, 500);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n\n    X", str);
    }
}

test "Terminal: cursorUp resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorUp(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: cursorDown resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorDown(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\n    X", str);
    }
}

test "Terminal: cursorRight resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorRight(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: cursorRight to the edge of screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.cursorRight(100);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    X", str);
    }
}

test "Terminal: insert mode with space" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.modes.set(.insert, true);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hXello", str);
    }
}

test "Terminal: insert mode doesn't wrap pushed characters" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.modes.set(.insert, true);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hXell", str);
    }
}

test "Terminal: insert mode does nothing at the end of the line" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    t.modes.set(.insert, true);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello\nX", str);
    }
}

test "Terminal: insert mode with wide characters" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.modes.set(.insert, true);
    try t.print('😀'); // 0x1F600

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("h😀el", str);
    }
}

test "Terminal: insert mode with wide characters at end" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    for ("well") |c| try t.print(c);
    t.modes.set(.insert, true);
    try t.print('😀'); // 0x1F600

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("well\n😀", str);
    }
}

test "Terminal: insert mode pushing off wide character" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    for ("123") |c| try t.print(c);
    try t.print('😀'); // 0x1F600
    t.modes.set(.insert, true);
    t.setCursorPos(1, 1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X123", str);
    }
}

test "Terminal: saveCursor origin mode" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.modes.set(.origin, true);
    t.saveCursor();
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setTopAndBottomMargin(2, 4);
    t.restoreCursor();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X", str);
    }
}

test "Terminal: saveCursor resize" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(1, 10);
    t.saveCursor();
    try t.resize(alloc, .{ .cols = 5, .rows = 5 });
    t.restoreCursor();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    X", str);
    }
}

test "Terminal: saveCursor doesn't modify hyperlink state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    try t.screens.active.startHyperlink("http://example.com", null);
    const id = t.screens.active.cursor.hyperlink_id;
    t.saveCursor();
    try testing.expectEqual(id, t.screens.active.cursor.hyperlink_id);
    t.restoreCursor();
    try testing.expectEqual(id, t.screens.active.cursor.hyperlink_id);
}

test "Terminal: setProtectedMode" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    try testing.expect(!t.screens.active.cursor.protected);
    t.setProtectedMode(.off);
    try testing.expect(!t.screens.active.cursor.protected);
    t.setProtectedMode(.iso);
    try testing.expect(t.screens.active.cursor.protected);
    t.setProtectedMode(.dec);
    try testing.expect(t.screens.active.cursor.protected);
    t.setProtectedMode(.off);
    try testing.expect(!t.screens.active.cursor.protected);
}

test "Terminal: semantic prompt" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Prompt
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x - 1,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(.prompt, cell.semantic_content);

        const row = list_cell.row;
        try testing.expectEqual(.prompt, row.semantic_prompt);
    }

    // Start input but end it on EOL
    try t.semanticPrompt(.init(.end_prompt_start_input_terminate_eol));
    t.carriageReturn();
    try t.linefeed();

    // Write some output
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    for ("world") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x - 1,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(.output, cell.semantic_content);

        const row = list_cell.row;
        try testing.expectEqual(.none, row.semantic_prompt);
    }
}

test "Terminal: semantic prompt continuations" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Prompt
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x - 1,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(.prompt, cell.semantic_content);

        const row = list_cell.row;
        try testing.expectEqual(.prompt, row.semantic_prompt);
    }

    // Start input but end it on EOL
    t.carriageReturn();
    try t.linefeed();
    try t.semanticPrompt(.{
        .action = .prompt_start,
        .options_unvalidated = "k=c",
    });

    // Write some output
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    for ("world") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x - 1,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(.prompt, cell.semantic_content);

        const row = list_cell.row;
        try testing.expectEqual(.prompt_continuation, row.semantic_prompt);
    }
}

test "Terminal: multiple newlines in prompt mode marks all rows" {
    // Multiple newlines should each mark their row as prompt continuation
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Start a prompt
    try t.semanticPrompt(.init(.prompt_start));
    for ("line1") |c| try t.print(c);

    // Multiple newlines
    t.carriageReturn();
    try t.linefeed();
    for ("line2") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("line3") |c| try t.print(c);

    // First row should be prompt
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).?;
        try testing.expectEqual(.prompt, list_cell.row.semantic_prompt);
    }

    // Second and third rows should be prompt continuation
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 2,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
}

test "Terminal: cursorIsAtPrompt alternate screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 2 });
    defer t.deinit(alloc);

    try testing.expect(!t.cursorIsAtPrompt());
    try t.semanticPrompt(.init(.prompt_start));
    try testing.expect(t.cursorIsAtPrompt());

    // Secondary screen is never a prompt
    try t.switchScreenMode(.@"1049", true);
    try testing.expect(!t.cursorIsAtPrompt());
    try t.semanticPrompt(.init(.prompt_start));
    try testing.expect(!t.cursorIsAtPrompt());
}

test "Terminal: fullReset with a non-empty pen" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    try t.setAttribute(.{ .direct_color_bg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    t.screens.active.cursor.semantic_content = .input;
    t.fullReset();

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.style_id == 0);
    }

    try testing.expectEqual(@as(style.Id, 0), t.screens.active.cursor.style_id);
    try testing.expectEqual(.output, t.screens.active.cursor.semantic_content);
}

test "Terminal: fullReset hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.screens.active.startHyperlink("http://example.com", null);
    t.fullReset();
    try testing.expectEqual(0, t.screens.active.cursor.hyperlink_id);
}

test "Terminal: fullReset with a non-empty saved cursor" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    try t.setAttribute(.{ .direct_color_bg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    t.saveCursor();
    t.fullReset();

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.style_id == 0);
    }

    try testing.expectEqual(@as(style.Id, 0), t.screens.active.cursor.style_id);
}

test "Terminal: fullReset origin mode" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    t.setCursorPos(3, 5);
    t.modes.set(.origin, true);
    t.fullReset();

    // Origin mode should be reset and the cursor should be moved
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expect(!t.modes.get(.origin));
}

test "Terminal: fullReset status display" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    t.status_display = .status_line;
    t.fullReset();
    try testing.expect(t.status_display == .main);
}

test "Terminal: fullReset preserves kitty graphics limits" {
    const alloc = testing.allocator;
    const temp_dir = "/tmp/ghostty-kitty-images";

    var t = try init(testing.io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    t.setKittyGraphicsLoadingLimits(.allWithTempDir(temp_dir));
    for ([_]usize{ 1234, 0 }) |total_limit| {
        t.setKittyGraphicsSizeLimit(alloc, total_limit);
        t.fullReset();

        const storage = &t.screens.active.kitty_images;
        try testing.expectEqual(total_limit, storage.total_limit);
        try testing.expect(storage.image_limits.file);
        try testing.expect(storage.image_limits.shared_memory);
        switch (storage.image_limits.temporary_file) {
            .enabled => |value| try testing.expectEqualStrings(
                temp_dir,
                value.directory,
            ),
            .disabled => return error.TestUnexpectedResult,
        }
    }
}

test "Terminal: fullReset default modes" {
    var t = try init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 10,
        .default_modes = .{ .grapheme_cluster = true },
    });
    defer t.deinit(testing.allocator);
    try testing.expect(t.modes.get(.grapheme_cluster));
    t.fullReset();
    try testing.expect(t.modes.get(.grapheme_cluster));
}

test "Terminal: fullReset tracked pins" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Create a tracked pin
    const p = try t.screens.active.pages.trackPin(t.screens.active.cursor.page_pin.*);
    t.fullReset();
    try testing.expect(t.screens.active.pages.pinIsValid(p.*));
}

// https://github.com/mitchellh/ghostty/issues/1343
test "Terminal: resize with wraparound off" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    const cols = 4;
    const rows = 2;
    var t = try init(io_impl, alloc, .{ .cols = cols, .rows = rows });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, false);
    try t.print('0');
    try t.print('1');
    try t.print('2');
    try t.print('3');
    const new_cols = 2;
    try t.resize(alloc, .{ .cols = new_cols, .rows = rows });

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("01", str);
}

test "Terminal: resize with wraparound on" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    const cols = 4;
    const rows = 2;
    var t = try init(io_impl, alloc, .{ .cols = cols, .rows = rows });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    try t.print('0');
    try t.print('1');
    try t.print('2');
    try t.print('3');
    const new_cols = 2;
    try t.resize(alloc, .{ .cols = new_cols, .rows = rows });

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("01\n23", str);
}

test "Terminal: resize with high unique style per cell" {
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

    try t.resize(alloc, .{ .cols = 60, .rows = 30 });
}

test "Terminal: resize with high unique style per cell with wrapping" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 30, .rows = 30 });
    defer t.deinit(alloc);

    const cell_count: u16 = @intCast(t.rows * t.cols);
    for (0..cell_count) |i| {
        const r: u8 = @intCast(i >> 8);
        const g: u8 = @intCast(i & 0xFF);

        try t.setAttribute(.{ .direct_color_bg = .{
            .r = r,
            .g = g,
            .b = 0,
        } });
        try t.print('x');
    }

    try t.resize(alloc, .{ .cols = 60, .rows = 30 });
}

test "Terminal: resize with reflow and saved cursor" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("1A2B");
    t.setCursorPos(2, 2);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u32, 'B'), cell.content.codepoint.data);
    }

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A\n2B", str);
    }

    t.saveCursor();
    try t.resize(alloc, .{ .cols = 5, .rows = 3 });
    t.restoreCursor();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A2B", str);
    }

    // Verify our cursor is still in the same place
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u32, 'B'), cell.content.codepoint.data);
    }
}

test "Terminal: resize with reflow and saved cursor pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("1A2B");
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u32, 'B'), cell.content.codepoint.data);
    }

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A\n2B", str);
    }

    t.saveCursor();
    try t.resize(alloc, .{ .cols = 5, .rows = 3 });
    t.restoreCursor();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A2B", str);
    }

    // Pending wrap should be reset
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A2BX", str);
    }
}

test "Terminal: DECCOLM without DEC mode 40" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.@"132_column", true);
    try t.deccolm(alloc, .@"132_cols");
    try testing.expectEqual(@as(usize, 5), t.cols);
    try testing.expectEqual(@as(usize, 5), t.rows);
    try testing.expect(!t.modes.get(.@"132_column"));
}

test "Terminal: DECCOLM resets pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");
    try testing.expectEqual(@as(usize, 80), t.cols);
    try testing.expectEqual(@as(usize, 5), t.rows);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
}

test "Terminal: mode 47 alt screen plain" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Print on primary screen
    try t.printString("1A");

    // Go to alt screen with mode 47
    try t.switchScreenMode(.@"47", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Screen should be empty
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Print on alt screen. This should be off center because
    // we copy the cursor over from the primary screen
    try t.printString("2B");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  2B", str);
    }

    // Go back to primary
    try t.switchScreenMode(.@"47", false);
    try testing.expectEqual(.primary, t.screens.active_key);

    // Primary screen should still have the original content
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A", str);
    }

    // Go back to alt screen with mode 47
    try t.switchScreenMode(.@"47", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Screen should retain content
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  2B", str);
    }
}

test "Terminal: mode 47 copies cursor both directions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Color our cursor red
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });

    // Go to alt screen with mode 47
    try t.switchScreenMode(.@"47", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Verify that our style is set
    {
        try testing.expect(t.screens.active.cursor.style_id != style.default_id);
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 1), page.styles.count());
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 0);
    }

    // Set a new style
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0, .g = 0xFF, .b = 0 } });

    // Go back to primary
    try t.switchScreenMode(.@"47", false);
    try testing.expectEqual(.primary, t.screens.active_key);

    // Verify that our style is still set
    {
        try testing.expect(t.screens.active.cursor.style_id != style.default_id);
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 1), page.styles.count());
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 0);
    }
}

test "Terminal: mode 1047 alt screen plain" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Print on primary screen
    try t.printString("1A");

    // Go to alt screen with mode 47
    try t.switchScreenMode(.@"1047", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Screen should be empty
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Print on alt screen. This should be off center because
    // we copy the cursor over from the primary screen
    try t.printString("2B");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  2B", str);
    }

    // Go back to primary
    try t.switchScreenMode(.@"1047", false);
    try testing.expectEqual(.primary, t.screens.active_key);

    // Primary screen should still have the original content
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A", str);
    }

    // Go back to alt screen with mode 1047
    try t.switchScreenMode(.@"1047", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Screen should be empty
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: mode 1047 copies cursor both directions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Color our cursor red
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });

    // Go to alt screen with mode 47
    try t.switchScreenMode(.@"1047", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Verify that our style is set
    {
        try testing.expect(t.screens.active.cursor.style_id != style.default_id);
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 1), page.styles.count());
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 0);
    }

    // Set a new style
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0, .g = 0xFF, .b = 0 } });

    // Go back to primary
    try t.switchScreenMode(.@"1047", false);
    try testing.expectEqual(.primary, t.screens.active_key);

    // Verify that our style is still set
    {
        try testing.expect(t.screens.active.cursor.style_id != style.default_id);
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 1), page.styles.count());
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 0);
    }
}

test "Terminal: mode 1049 alt screen plain" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Print on primary screen
    try t.printString("1A");

    // Go to alt screen with mode 47
    try t.switchScreenMode(.@"1049", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Screen should be empty
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Print on alt screen. This should be off center because
    // we copy the cursor over from the primary screen
    try t.printString("2B");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  2B", str);
    }

    // Go back to primary
    try t.switchScreenMode(.@"1049", false);
    try testing.expectEqual(.primary, t.screens.active_key);

    // Primary screen should still have the original content
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A", str);
    }

    // Write, our cursor should be restored back.
    try t.printString("C");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1AC", str);
    }

    // Go back to alt screen with mode 1049
    try t.switchScreenMode(.@"1049", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Screen should be empty
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}
