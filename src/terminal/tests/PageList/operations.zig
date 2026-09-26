//! PageList operations regression tests.
const support = @import("support.zig");
const std = support.std;
const point = support.point;
const size = support.size;
const std_capacity = support.std_capacity;
const std_size = support.std_size;
const PagePool = support.PagePool;
const Viewport = support.Viewport;
const initialCapacity = support.initialCapacity;
const init_tw = support.init_tw;
const init = support.init;
const initPages_tw = support.initPages_tw;
const trimTrailingBlankRows = support.trimTrailingBlankRows;
const Scrollbar = support.Scrollbar;
const PageIterator = support.PageIterator;
const totalRows = support.totalRows;
const growRows = support.growRows;
const Pin = support.Pin;
const expectLivePageSerialsValidForTest = support.expectLivePageSerialsValidForTest;

test "PageList" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));

    // Initial total rows should be our row count
    try testing.expectEqual(s.rows, s.total_rows);

    // Our viewport pin must be defined. It isn't used until the
    // viewport is a pin but it prevents undefined access on clone.
    try testing.expect(s.viewport_pin.node == s.pages.first.?);

    // Active area should be the top
    try testing.expectEqual(Pin{
        .node = s.pages.first.?,
        .y = 0,
        .x = 0,
    }, s.getTopLeft(.active));

    // Scrollbar should be where we expect it
    try testing.expectEqual(Scrollbar{
        .total = s.rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList init error" {
    // Test every failure point in `init` and ensure that we don't
    // leak memory (testing.allocator verifies) since we're exiting early.
    for (std.meta.tags(init_tw.FailPoint)) |tag| {
        const tw = init_tw;
        defer tw.end(.reset) catch unreachable;
        tw.errorAlways(tag, error.OutOfMemory);
        try std.testing.expectError(
            error.OutOfMemory,
            init(std.testing.allocator, .{
                .cols = 80,
                .rows = 24,
            }),
        );
    }

    // init calls initPages transitively, so let's check that if
    // any failures happen in initPages, we also don't leak memory.
    for (std.meta.tags(initPages_tw.FailPoint)) |tag| {
        const tw = initPages_tw;
        defer tw.end(.reset) catch unreachable;
        tw.errorAlways(tag, error.OutOfMemory);

        const cols: size.CellCountInt = if (tag == .page_buf_std) 80 else std_capacity.maxCols().? + 1;
        try std.testing.expectError(
            error.OutOfMemory,
            init(std.testing.allocator, .{
                .cols = cols,
                .rows = 24,
            }),
        );
    }

    // Try non-standard pages since they don't go in our pool.
    for ([_]initPages_tw.FailPoint{
        .page_buf_non_std,
    }) |tag| {
        const tw = initPages_tw;
        defer tw.end(.reset) catch unreachable;
        tw.errorAfter(tag, error.OutOfMemory, 1);
        try std.testing.expectError(
            error.OutOfMemory,
            init(std.testing.allocator, .{
                .cols = std_capacity.maxCols().? + 1,
                .rows = std_capacity.rows + 1,
            }),
        );
    }
}

test "PageList init rows across two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Find a cap that makes it so that rows don't fit on one page.
    const rows = 100;
    const cap = cap: {
        var cap = try std_capacity.adjust(.{ .cols = 50 });
        while (cap.rows >= rows) cap = try std_capacity.adjust(.{
            .cols = cap.cols + 50,
        });

        break :cap cap;
    };

    // Init
    var s = try init(alloc, .{ .cols = cap.cols, .rows = rows });
    defer s.deinit();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));

    // Initial total rows should be our row count
    try testing.expectEqual(s.rows, s.total_rows);

    // Scrollbar should be where we expect it
    try testing.expectEqual(Scrollbar{
        .total = s.rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList init more than max cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize with more columns than we can fit in our standard
    // capacity. This is going to force us to go to a non-standard page
    // immediately.
    var s = try init(alloc, .{
        .cols = std_capacity.maxCols().? + 1,
        .rows = 80,
    });
    defer s.deinit();
    try testing.expect(s.viewport == .active);
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));

    // We expect a single, non-standard page
    try testing.expect(s.pages.first != null);
    try testing.expect(s.pages.first.?.page().memory.len > std_size);

    // Initial total rows should be our row count
    try testing.expectEqual(s.rows, s.total_rows);

    // Scrollbar should be where we expect it
    try testing.expectEqual(Scrollbar{
        .total = s.rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList: jump zero prompts" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer s.deinit();
    try growRows(&s, 3);
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 1);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }

    s.scroll(.{ .delta_prompt = 0 });
    try testing.expect(s.viewport == .active);

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList: jump minimum prompt delta" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 10, .rows = 3 });
    defer s.deinit();

    s.scroll(.{ .delta_prompt = std.math.minInt(isize) });
    try testing.expectEqual(Viewport.active, s.viewport);
}

test "Screen: jump back one prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer s.deinit();
    try growRows(&s, 3);
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 1);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }

    // Jump back
    {
        s.scroll(.{ .delta_prompt = -1 });
        try testing.expect(s.viewport == .pin);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pointFromPin(.screen, s.pin(.{ .viewport = .{} }).?).?);

        try testing.expectEqual(Scrollbar{
            .total = s.total_rows,
            .offset = 1,
            .len = s.rows,
        }, s.scrollbar());
    }
    {
        s.scroll(.{ .delta_prompt = -1 });
        try testing.expect(s.viewport == .pin);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pointFromPin(.screen, s.pin(.{ .viewport = .{} }).?).?);

        try testing.expectEqual(Scrollbar{
            .total = s.total_rows,
            .offset = 1,
            .len = s.rows,
        }, s.scrollbar());
    }

    // Jump forward
    {
        s.scroll(.{ .delta_prompt = 1 });
        try testing.expect(s.viewport == .active);
        try testing.expectEqual(Scrollbar{
            .total = s.total_rows,
            .offset = s.total_rows - s.rows,
            .len = s.rows,
        }, s.scrollbar());
    }
    {
        s.scroll(.{ .delta_prompt = 1 });
        try testing.expect(s.viewport == .active);
        try testing.expectEqual(Scrollbar{
            .total = s.total_rows,
            .offset = s.total_rows - s.rows,
            .len = s.rows,
        }, s.scrollbar());
    }
}

test "Screen: jump forward prompt skips multiline continuation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer s.deinit();
    try growRows(&s, 7);

    // Multiline prompt on rows 1-3.
    {
        const p = s.pin(.{ .screen = .{ .y = 1 } }).?;
        p.rowAndCell().row.semantic_prompt = .prompt;
    }
    {
        const p = s.pin(.{ .screen = .{ .y = 2 } }).?;
        p.rowAndCell().row.semantic_prompt = .prompt_continuation;
    }
    {
        const p = s.pin(.{ .screen = .{ .y = 3 } }).?;
        p.rowAndCell().row.semantic_prompt = .prompt_continuation;
    }

    // Next prompt after command output.
    {
        const p = s.pin(.{ .screen = .{ .y = 6 } }).?;
        p.rowAndCell().row.semantic_prompt = .prompt;
    }

    // Starting at the first prompt line should jump to the next prompt,
    // not to continuation lines.
    s.scroll(.{ .row = 1 });
    s.scroll(.{ .delta_prompt = 1 });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 6,
    } }, s.pointFromPin(.screen, s.pin(.{ .viewport = .{} }).?).?);

    // Starting in the middle of continuation lines should also jump to
    // the next prompt.
    s.scroll(.{ .row = 2 });
    s.scroll(.{ .delta_prompt = 1 });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 6,
    } }, s.pointFromPin(.screen, s.pin(.{ .viewport = .{} }).?).?);
}

test "PageList set max bytes zero preserves active boundary" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 1,
        .max_size = null,
    });
    defer s.deinit();

    // Make the sole page larger than the effective zero-byte limit. Its first
    // row will be history, but the same indivisible page also contains active.
    while (s.page_size <= s.limits.bytes.min) {
        _ = try s.increaseCapacity(s.pages.first.?, .grapheme_bytes);
    }
    _ = try s.grow();
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    try testing.expectEqual(s.pages.first.?, s.getTopLeft(.active).node);
    try testing.expect(s.getTopLeft(.active).y > 0);

    s.scroll(.top);
    try testing.expect(s.viewport == .top);

    s.setMaxBytes(0);
    try testing.expectEqual(@as(usize, 0), s.limits.bytes.explicit);
    try testing.expect(s.page_size > s.limits.max(.bytes));
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    try testing.expect(s.viewport == .active);
    try testing.expectEqual(Scrollbar{
        .total = s.rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());

    // No-scrollback mode cannot be moved back into the retained boundary row.
    s.scroll(.top);
    try testing.expect(s.viewport == .active);
}

test "PageList max lines uses one-page minimum" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;

    var s = try init(testing.allocator, .{
        .cols = cols,
        .rows = 1,
        .max_lines = page_rows / 2,
    });
    defer s.deinit();

    try testing.expectEqual(page_rows, s.limits.max(.lines));

    // The requested limit is below one page, so a complete page of history
    // remains valid.
    try growRows(&s, page_rows);
    try testing.expectEqual(page_rows, s.total_rows - s.rows);
    try testing.expectEqual(@as(usize, 2), s.totalPages());

    const first = s.pages.first.?;
    const old_page_size = s.page_size;

    // One more row puts us over the effective limit. The now-complete
    // historical page is removed rather than partially trimmed.
    _ = try s.grow();
    try testing.expectEqual(@as(usize, 1), s.total_rows - s.rows);
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    try testing.expect(s.pages.first.? != first);
    try testing.expectEqual(
        old_page_size - PagePool.item_size,
        s.page_size,
    );
}

test "PageList row erasure renews affected page generations" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    while (s.totalPages() < 2) _ = try s.grow();

    const first = s.pages.first.?;
    const second = first.next.?;
    var first_serial = first.serial;
    var second_serial = second.serial;
    var activity = s.page_compression.activity_serial;

    try s.eraseRow(.{ .history = .{ .y = 0 } });
    try testing.expect(!s.nodeIsValid(first, first_serial));
    try testing.expect(!s.nodeIsValid(second, second_serial));
    try testing.expect(activity != s.page_compression.activity_serial);

    first_serial = first.serial;
    second_serial = second.serial;
    activity = s.page_compression.activity_serial;
    try s.eraseRowBounded(
        .{ .history = .{ .y = 0 } },
        first.rows() + 1,
    );
    try testing.expect(!s.nodeIsValid(first, first_serial));
    try testing.expect(!s.nodeIsValid(second, second_serial));
    try testing.expect(activity != s.page_compression.activity_serial);
}

test "PageList trailing row truncation renews page generation" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    const node = s.pages.last.?;
    const old_serial = node.serial;
    const trimmed = trimTrailingBlankRows(&s, 1);
    s.total_rows -= trimmed;
    try testing.expectEqual(@as(size.CellCountInt, 1), trimmed);
    try testing.expect(!s.nodeIsValid(node, old_serial));

    _ = try s.grow();
    try expectLivePageSerialsValidForTest(&s);
}

test "PageList pageIterator single page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // The viewport should be within a single page
    try testing.expect(s.pages.first.?.next == null);

    // Iterate the active area
    var it = s.pageIterator(.right_down, .{ .active = .{} }, null);
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        try testing.expectEqual(@as(usize, 0), chunk.start);
        try testing.expectEqual(@as(usize, s.rows), chunk.end);
    }

    // Should only have one chunk
    try testing.expect(it.next() == null);
}

test "PageList pageIterator two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow to capacity
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);

    // Iterate the active area
    var it = s.pageIterator(.right_down, .{ .active = .{} }, null);
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        const start = chunk.node.rows() - s.rows + 1;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(chunk.node.rows(), chunk.end);
    }
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.last.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(start + 1, chunk.end);
    }
    try testing.expect(it.next() == null);
}

test "PageList pageIterator history two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow to capacity
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);

    // Iterate the active area
    var it = s.pageIterator(.right_down, .{ .history = .{} }, null);
    {
        const active_tl = s.getTopLeft(.active);
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(active_tl.y, chunk.end);
    }
    try testing.expect(it.next() == null);
}

test "PageList pageIterator reverse single page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // The viewport should be within a single page
    try testing.expect(s.pages.first.?.next == null);

    // Iterate the active area
    var it = s.pageIterator(.left_up, .{ .active = .{} }, null);
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        try testing.expectEqual(@as(usize, 0), chunk.start);
        try testing.expectEqual(@as(usize, s.rows), chunk.end);
    }

    // Should only have one chunk
    try testing.expect(it.next() == null);
}

test "PageList pageIterator reverse two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow to capacity
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);

    // Iterate the active area
    var it = s.pageIterator(.left_up, .{ .active = .{} }, null);
    var count: usize = 0;
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.last.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(start + 1, chunk.end);
        count += chunk.end - chunk.start;
    }
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        const start = chunk.node.rows() - s.rows + 1;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(chunk.node.rows(), chunk.end);
        count += chunk.end - chunk.start;
    }
    try testing.expect(it.next() == null);
    try testing.expectEqual(s.rows, count);
}

test "PageList pageIterator reverse history two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow to capacity
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);

    // Iterate the active area
    var it = s.pageIterator(.left_up, .{ .history = .{} }, null);
    {
        const active_tl = s.getTopLeft(.active);
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(active_tl.y, chunk.end);
    }
    try testing.expect(it.next() == null);
}

test "PageList PageIterator reverse count includes row zero" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 2 });
    defer s.deinit();

    var it: PageIterator = .{
        .row = s.getTopLeft(.screen),
        .limit = .{ .count = 1 },
        .direction = .left_up,
    };
    const chunk = it.next().?;
    try testing.expectEqual(@as(size.CellCountInt, 0), chunk.start);
    try testing.expectEqual(@as(size.CellCountInt, 1), chunk.end);
    try testing.expect(it.next() == null);
}

test "PageList PageIterator count crosses page boundaries" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    const first = s.pages.first.?;
    first.page().pauseIntegrityChecks(true);
    while (first.rows() < first.capacity().rows) _ = try s.grow();
    first.page().pauseIntegrityChecks(false);
    const second = (try s.grow()).?;

    var down: PageIterator = .{
        .row = .{ .node = first, .y = first.rows() - 1 },
        .limit = .{ .count = 2 },
        .direction = .right_down,
    };
    {
        const chunk = down.next().?;
        try testing.expectEqual(first, chunk.node);
        try testing.expectEqual(first.rows() - 1, chunk.start);
        try testing.expectEqual(first.rows(), chunk.end);
    }
    {
        const chunk = down.next().?;
        try testing.expectEqual(second, chunk.node);
        try testing.expectEqual(@as(size.CellCountInt, 0), chunk.start);
        try testing.expectEqual(@as(size.CellCountInt, 1), chunk.end);
    }
    try testing.expect(down.next() == null);

    var up: PageIterator = .{
        .row = .{ .node = second },
        .limit = .{ .count = 2 },
        .direction = .left_up,
    };
    {
        const chunk = up.next().?;
        try testing.expectEqual(second, chunk.node);
        try testing.expectEqual(@as(size.CellCountInt, 0), chunk.start);
        try testing.expectEqual(@as(size.CellCountInt, 1), chunk.end);
    }
    {
        const chunk = up.next().?;
        try testing.expectEqual(first, chunk.node);
        try testing.expectEqual(first.rows() - 1, chunk.start);
        try testing.expectEqual(first.rows(), chunk.end);
    }
    try testing.expect(up.next() == null);
}

test "PageList cellIterator" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    var it = s.cellIterator(.right_down, .{ .screen = .{} }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList cellIterator reverse" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    var it = s.cellIterator(.left_up, .{ .screen = .{} }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList promptIterator left_up" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    // Normal prompt
    {
        const rac = page.getRowAndCell(0, 3);
        rac.row.semantic_prompt = .prompt;
    }
    // Continuation
    {
        const rac = page.getRowAndCell(0, 6);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 7);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 8);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    // Broken continuation that has non-prompts in between
    {
        const rac = page.getRowAndCell(0, 12);
        rac.row.semantic_prompt = .prompt_continuation;
    }

    var it = s.promptIterator(.left_up, .{ .screen = .{} }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 12,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 6,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList promptIterator right_down" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    // Normal prompt
    {
        const rac = page.getRowAndCell(0, 3);
        rac.row.semantic_prompt = .prompt;
    }
    // Continuation (prompt on row 6, continuation on rows 7-8)
    {
        const rac = page.getRowAndCell(0, 6);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 7);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 8);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    // Broken continuation that has non-prompts in between (orphaned continuation at row 12)
    {
        const rac = page.getRowAndCell(0, 12);
        rac.row.semantic_prompt = .prompt_continuation;
    }

    var it = s.promptIterator(.right_down, .{ .screen = .{} }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 6,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 12,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList promptIterator right_down continuation at start" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt continuation at row 0 (no prior rows - simulates trimmed scrollback)
    {
        const rac = page.getRowAndCell(0, 0);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 1);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    // Normal prompt later
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }

    var it = s.promptIterator(.right_down, .{ .screen = .{} }, null);
    {
        // Should return the first continuation line since there's no prior prompt
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList promptIterator right_down with prompt before continuation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 2, continuation on rows 3-4
    // Starting iteration from row 3 should still find the prompt at row 2
    {
        const rac = page.getRowAndCell(0, 2);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 3);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 4);
        rac.row.semantic_prompt = .prompt_continuation;
    }

    // Start iteration from row 3 (middle of the continuation)
    // Since we start on a continuation line, we treat it as the prompt start
    // (handles case where scrollback pruned the actual prompt)
    var it = s.promptIterator(.right_down, .{ .screen = .{ .y = 3 } }, null);
    {
        const p = it.next().?;
        // Returns row 3 since that's the first prompt-related line we encounter
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList highlightSemanticContent prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // Start the prompt for the first 5 cols
        for (0..5) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
                .semantic_content = .prompt,
            };
        }

        // Next 3 let's make input
        for (5..8) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'B' } },
                .semantic_content = .input,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 2, .y = 5 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent prompt with output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 3 cols are prompt
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }

        // Next 4 are input
        for (3..7) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'l' } },
                .semantic_content = .input,
            };
        }

        // Rest is output (shouldn't be included in prompt highlight)
        for (7..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting from prompt should include prompt and input, but stop at output
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 6,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent prompt multiline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt starts on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First row is all prompt
        for (0..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
    }
    // Row 6 continues with input
    {
        for (0..5) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting should span both rows
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 2, .y = 5 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 6,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent prompt only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5 with only prompt content (no input)
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        for (0..5) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting should only include the prompt cells
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent prompt to end of screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Single prompt on row 15, no following prompt
    {
        const rac = page.getRowAndCell(0, 15);
        rac.row.semantic_prompt = .prompt;

        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }

        for (3..8) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }
    }

    // Highlighting should include prompt and input up to column 7
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 15 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent input basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 3 cols are prompt
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }

        // Next 5 are input
        for (3..8) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'l' } },
                .semantic_content = .input,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting input should only include input cells
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 3,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent input with output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 2 cols are prompt
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }

        // Next 3 are input
        for (2..5) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }

        // Rest is output
        for (5..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting input should stop at output
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 2,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent input multiline with continuation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 2 cols are prompt
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }

        // Rest is input
        for (2..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }
    }
    // Row 6 has continuation prompt then more input
    {
        // Continuation prompt
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '>' } },
                .semantic_content = .prompt,
            };
        }

        // More input
        for (2..6) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'd' } },
                .semantic_content = .input,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting input should span both rows, skipping continuation prompts
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 2,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 5,
        .y = 6,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent input no input returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5 with only prompt, then immediately output
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 3 cols are prompt
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }

        // Rest is output (no input!)
        for (3..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting input should return null when there's no input
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    );
    try testing.expect(hl == null);
}

test "PageList highlightSemanticContent input to end of screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Single prompt on row 15, no following prompt
    {
        const rac = page.getRowAndCell(0, 15);
        rac.row.semantic_prompt = .prompt;

        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }

        for (2..7) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }
    }

    // Highlighting input with no following prompt
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 15 } }).?,
        .input,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 2,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 6,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent input prompt only returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5 with only prompt content, no input or output
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // All cells are prompt
        for (0..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
    }
    // Mark rows 6-9 as prompt to ensure no input before next prompt
    {
        for (6..10) |y| {
            for (0..10) |x| {
                const cell = page.getRowAndCell(x, y).cell;
                cell.semantic_content = .prompt;
            }
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting input should return null when there's only prompts
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    );
    try testing.expect(hl == null);
}

test "PageList highlightSemanticContent output basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 2 cols are prompt
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }

        // Next 3 are input
        for (2..5) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'l' } },
                .semantic_content = .input,
            };
        }

        // Cols 5-7 are output
        for (5..8) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }

        // Mark remaining cells as prompt to bound the output
        for (8..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.semantic_content = .prompt;
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting output should only include output cells
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 5,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent output multiline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 2 cols are prompt
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }

        // Next 2 are input
        for (2..4) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'l' } },
                .semantic_content = .input,
            };
        }

        // Rest of row 5 is output
        for (4..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    // Row 6 is all output
    {
        for (0..10) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    // Row 7 has partial output then input to bound it
    {
        for (0..5) |x| {
            const cell = page.getRowAndCell(x, 7).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
        for (5..10) |x| {
            const cell = page.getRowAndCell(x, 7).cell;
            cell.semantic_content = .input;
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting output should span multiple rows
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 7,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent output stops at next prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 2 cols are prompt
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }

        // Next 2 are input
        for (2..4) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'l' } },
                .semantic_content = .input,
            };
        }

        // Rest is output
        for (4..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    // Row 6 has output then prompt starts
    {
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
        // Next prompt marker on same row
        for (3..6) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting output should stop before prompt/input
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 2,
        .y = 6,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent output to end of screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Single prompt on row 15, no following prompt
    {
        const rac = page.getRowAndCell(0, 15);
        rac.row.semantic_prompt = .prompt;

        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }

        for (2..4) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }

        for (4..10) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    // Row 16 has output then prompt to bound it
    {
        for (0..8) |x| {
            const cell = page.getRowAndCell(x, 16).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
        for (8..10) |x| {
            const cell = page.getRowAndCell(x, 16).cell;
            cell.semantic_content = .prompt;
        }
    }

    // Highlighting output with no following prompt
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 15 } }).?,
        .output,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 16,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent output no output returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5 with only prompt and input, no output
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 3 cols are prompt
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }

        // Rest is input (must explicitly mark all cells to avoid default .output)
        for (3..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }
    }
    // Mark rows 6-9 as input to ensure no output between prompts
    {
        for (6..10) |y| {
            for (0..10) |x| {
                const cell = page.getRowAndCell(x, y).cell;
                cell.semantic_content = .input;
            }
        }
    }
    // Prompt on row 10 (no output between prompts)
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting output should return null when there's no output
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    );
    try testing.expect(hl == null);
}

test "PageList highlightSemanticContent output skips empty cells" {
    // Tests that empty cells with default .output semantic content are
    // not selected as output. This can happen when a prompt/input line
    // doesn't fill the entire row - trailing cells have default .output.
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5 - only fills first 3 cells, rest are empty with default .output
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 3 cols are prompt with text
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
        // Cells 3-9 are empty (codepoint = 0) with default .output semantic content
        // This simulates what happens when a short prompt is written
    }

    // Row 6 has input (short, doesn't fill line)
    {
        for (0..4) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'l' } },
                .semantic_content = .input,
            };
        }
        // Cells 4-9 are empty with default .output
    }

    // Row 7-8 have actual output with text
    {
        for (7..9) |y| {
            for (0..5) |x| {
                const cell = page.getRowAndCell(x, y).cell;
                cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = 'o' } },
                    .semantic_content = .output,
                };
            }
        }
    }

    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting output should skip empty cells on rows 5-6 and find
    // the actual output starting at row 7
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    ).?;
    // Output should start at row 7, not row 5 (where empty cells have default .output)
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 7,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 8,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList reset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    s.reset();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));

    // Active area should be the top
    try testing.expectEqual(Pin{
        .node = s.pages.first.?,
        .y = 0,
        .x = 0,
    }, s.getTopLeft(.active));
}

test "PageList reset across two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Find a cap that makes it so that rows don't fit on one page.
    const rows = 100;
    const cap = cap: {
        var cap = try std_capacity.adjust(.{ .cols = 50 });
        while (cap.rows >= rows) cap = try std_capacity.adjust(.{
            .cols = cap.cols + 50,
        });

        break :cap cap;
    };

    // Init
    var s = try init(alloc, .{ .cols = cap.cols, .rows = rows });
    defer s.deinit();
    s.reset();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));
}

test "PageList clears history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 30);
    s.reset();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));

    // Active area should be the top
    try testing.expectEqual(Pin{
        .node = s.pages.first.?,
        .y = 0,
        .x = 0,
    }, s.getTopLeft(.active));
}

test "PageList compact then reset frees heap pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();

    // Compact the only page so the list contains a sub-std_size
    // heap-owned page.
    const node = (try s.compact(s.pages.first.?)).?;
    try testing.expectEqual(.heap, node.owned);
    try testing.expect(node.page().memory.len < std_size);

    // Reset must free the heap page (testing allocator catches leaks
    // and invalid frees) and rebuild from the pool.
    s.reset();
    try testing.expectEqual(.pool, s.pages.first.?.owned);
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));
}

test "PageList compact oversized page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow until we have multiple pages
    const page1_node = s.pages.first.?;
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1_node.capacity().rows - page1_node.rows()) |_| {
        _ = try s.grow();
    }
    page1_node.page().pauseIntegrityChecks(false);
    _ = try s.grow();
    try testing.expect(s.pages.first != s.pages.last);

    var node = s.pages.first.?;

    // Write content to verify it's preserved
    {
        const page = node.page();
        for (0..page.size.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(x + y * s.cols) } },
                };
            }
        }
    }

    // Create a tracked pin on this page
    const tracked = try s.trackPin(.{ .node = node, .x = 5, .y = 10 });
    defer s.untrackPin(tracked);

    // Make the page oversized
    while (node.page().memory.len <= std_size) {
        node = try s.increaseCapacity(node, .grapheme_bytes);
    }
    try testing.expect(node.page().memory.len > std_size);
    const oversized_len = node.page().memory.len;
    const original_size = node.page().size;
    const second_node = node.next.?;

    // Set dirty flag after increaseCapacity
    node.page().dirty = true;

    // Compact the page
    const new_node = try s.compact(node);
    try testing.expect(new_node != null);

    // Verify memory is smaller
    try testing.expect(new_node.?.page().memory.len < oversized_len);

    // Verify size preserved
    try testing.expectEqual(original_size.rows, new_node.?.rows());
    try testing.expectEqual(original_size.cols, new_node.?.cols());

    // Verify dirty flag preserved
    try testing.expect(new_node.?.page().dirty);

    // Verify linked list integrity
    try testing.expectEqual(new_node.?, s.pages.first.?);
    try testing.expectEqual(null, new_node.?.prev);
    try testing.expectEqual(second_node, new_node.?.next);
    try testing.expectEqual(new_node.?, second_node.prev);

    // Verify pin updated correctly
    try testing.expectEqual(new_node.?, tracked.node);
    try testing.expectEqual(@as(size.CellCountInt, 5), tracked.x);
    try testing.expectEqual(@as(size.CellCountInt, 10), tracked.y);

    // Verify content preserved
    const page = new_node.?.page();
    for (0..page.size.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            try testing.expectEqual(
                @as(u21, @intCast(x + y * s.cols)),
                rac.cell.content.codepoint.data,
            );
        }
    }
}
