//! PageList reflow regression tests.
const nodeIsCompressed = support.nodeIsCompressed;
const support = @import("support.zig");
const std = support.std;
const assert = support.assert;
const kitty = support.kitty;
const point = support.point;
const pagepkg = support.pagepkg;
const stylepkg = support.stylepkg;
const size = support.size;
const std_capacity = support.std_capacity;
const std_size = support.std_size;
const Viewport = support.Viewport;
const initialCapacity = support.initialCapacity;
const init = support.init;
const resizeWithoutReflow = support.resizeWithoutReflow;
const Scrollbar = support.Scrollbar;
const IncrementalCompressionResult = support.IncrementalCompressionResult;
const totalRows = support.totalRows;
const growRows = support.growRows;
const growColdPagesForTest = support.growColdPagesForTest;

test "PageList incremental compression restarts after active boundary resize" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, 1);

    const initial = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, initial);
    try testing.expect(nodeIsCompressed(s.pages.first.?));

    const first = s.pages.first.?;
    const all_rows: size.CellCountInt = @intCast(s.total_rows);
    try s.resize(.{ .rows = all_rows });
    try testing.expectEqual(first, s.getTopLeft(.active).node);

    // Restore the page while it is active. Resize reset the traversal, and
    // active contents remain ineligible.
    _ = first.page();
    const active = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, active);
    try testing.expectEqual(
        IncrementalCompressionResult.complete,
        s.compress(.incremental),
    );

    // Shrinking the active area makes the page fully historical again. The
    // resize reset the PageList-owned cursor, so the next step can reclaim it.
    try s.resize(.{ .rows = 24 });
    try growColdPagesForTest(&s, 1);
    try testing.expectEqual(
        IncrementalCompressionResult.pending,
        s.compress(.incremental),
    );
    try testing.expect(nodeIsCompressed(first));
}

test "PageList lazily restores compressed history made active by resize" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, 1);

    const first = s.pages.first.?;
    first.page().getRowAndCell(0, 0).cell.* = .init('X');
    const memory_ptr = first.page().memory.ptr;
    const memory_len = first.page().memory.len;
    const page_size = s.page_size;

    _ = s.compress(.full);
    try testing.expect(nodeIsCompressed(first));

    // Pull all scrollback into the active area by making the viewport as tall
    // as the complete screen. A row-only resize needs only page metadata, so
    // the newly active page can remain compressed until its contents are used.
    const all_rows: size.CellCountInt = @intCast(s.total_rows);
    try s.resize(.{ .rows = all_rows });
    const active = s.getTopLeft(.active);
    try testing.expectEqual(first, active.node);
    try testing.expectEqual(@as(size.CellCountInt, 0), active.y);
    try testing.expect(nodeIsCompressed(first));
    try testing.expectEqual(page_size, s.page_size);

    // The compression pass must not reconsider the node now that it is active.
    // Content access follows the normal page boundary, which recommits and
    // restores the retained mapping before returning the cell.
    _ = s.compress(.full);
    try testing.expect(nodeIsCompressed(first));
    const cell = s.getCell(.{ .active = .{} }).?;
    try testing.expectEqual(@as(u21, 'X'), cell.cell.content.codepoint.data);
    try testing.expect(!nodeIsCompressed(first));
    try testing.expectEqual(memory_ptr, first.page().memory.ptr);
    try testing.expectEqual(memory_len, first.page().memory.len);
    try testing.expectEqual(page_size, s.page_size);
}

test "PageList grow fit in capacity" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // So we know we're using capacity to grow
    const last = s.pages.last.?.page();
    try testing.expect(last.size.rows < last.capacity.rows);

    // Grow
    try testing.expect(try s.grow() == null);
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, pt);
    }
}

test "PageList max lines applies to resize and clone" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;

    var s = try init(testing.allocator, .{
        .cols = cols,
        .rows = 2,
        .max_lines = page_rows,
    });
    defer s.deinit();

    try growRows(&s, page_rows);
    try testing.expectEqual(page_rows, s.total_rows - s.rows);

    // Prevent row shrinking from trimming the trailing active row instead of
    // turning it into history.
    const cell = s.getCell(.{ .active = .{ .y = 1 } }).?;
    cell.cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = .{ .data = 'A' } },
    };

    try s.resize(.{ .rows = 1, .reflow = false });
    try testing.expectEqual(@as(usize, 1), s.total_rows - s.rows);

    const new_cols: size.CellCountInt = cols + 1;
    try s.resize(.{ .cols = new_cols, .reflow = true });
    try testing.expectEqual(
        support.minMaxLines(new_cols),
        s.limits.lines.min,
    );

    // Exercise the same active-row shrink through the reflow path. Reflow
    // completes before the newly historical complete page is pruned.
    {
        var reflowed = try init(testing.allocator, .{
            .cols = cols,
            .rows = 2,
            .max_lines = page_rows,
        });
        defer reflowed.deinit();

        try growRows(&reflowed, page_rows);
        const active_cell = reflowed.getCell(.{ .active = .{ .y = 1 } }).?;
        active_cell.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };

        try reflowed.resize(.{
            .cols = new_cols,
            .rows = 1,
            .reflow = true,
        });
        try testing.expectEqual(
            support.minMaxLines(new_cols),
            reflowed.limits.lines.min,
        );
        try testing.expect(
            reflowed.total_rows - reflowed.rows <=
                reflowed.limits.max(.lines) or
                reflowed.pages.first.? ==
                    reflowed.getTopLeft(.active).node,
        );
    }

    var cloned = try s.clone(testing.allocator, .{
        .top = .{ .screen = .{} },
    });
    defer cloned.deinit();

    try testing.expectEqual(s.limits, cloned.limits);

    try growRows(&cloned, 2 * cloned.limits.max(.lines));
    try testing.expect(
        cloned.total_rows - cloned.rows <= cloned.limits.max(.lines) or
            cloned.pages.first.? == cloned.getTopLeft(.active).node,
    );
}

test "PageList increaseCapacity to increase styles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();

    const original_styles_cap = s.pages.first.?.capacity().styles;

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // Write all our data so we can assert its the same after
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(x) } },
                };
            }
        }
    }

    // Increase our styles
    _ = try s.increaseCapacity(s.pages.first.?, .styles);

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // Verify capacity doubled
        try testing.expectEqual(
            original_styles_cap * 2,
            page.capacity.styles,
        );

        // Verify data preserved
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x)),
                    rac.cell.content.codepoint.data,
                );
            }
        }
    }
}

test "PageList increaseCapacity styles projects capacity from page density" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();

    const original_cap = s.pages.first.?.capacity().styles;

    // Write styled cells so the page has a measurable per-row style
    // density (unlike the plain doubling test above, which grows a
    // page with no styles in use).
    const bold: stylepkg.Style = .{ .flags = .{ .bold = true } };
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                const style_id = try page.styles.add(page.memory, bold);
                rac.row.styled = true;
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
                    .style_id = style_id,
                };
            }
        }
    }

    _ = try s.increaseCapacity(s.pages.first.?, .styles);

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // The page uses only two active rows out of thousands of rows
        // of capacity, so the projected full-page need saturates the
        // 32x-per-event growth bound instead of merely doubling.
        try testing.expectEqual(
            original_cap * 32,
            page.capacity.styles,
        );

        // All cell content and styles are preserved by the growth.
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x + 1)),
                    rac.cell.content.codepoint.data,
                );
                try testing.expect(rac.cell.style_id != stylepkg.default_id);
                try testing.expect(bold.eql(
                    page.styles.get(page.memory, rac.cell.style_id).*,
                ));
            }
        }
    }
}

test "PageList increaseCapacity to increase graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();

    const original_cap = s.pages.first.?.capacity().grapheme_bytes;

    {
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
    }

    _ = try s.increaseCapacity(s.pages.first.?, .grapheme_bytes);

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        try testing.expectEqual(original_cap * 2, page.capacity.grapheme_bytes);

        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x)),
                    rac.cell.content.codepoint.data,
                );
            }
        }
    }
}

test "PageList increaseCapacity graphemes projects capacity from page density" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();

    const original_cap = s.pages.first.?.capacity().grapheme_bytes;

    // Write cells with grapheme data so the page has a measurable
    // per-row grapheme density (unlike the plain doubling test above,
    // which grows a page with no grapheme usage).
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
                };
                try page.appendGrapheme(rac.row, rac.cell, 0x0301);
                try page.appendGrapheme(rac.row, rac.cell, 0x0302);
            }
        }
    }

    _ = try s.increaseCapacity(s.pages.first.?, .grapheme_bytes);

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // The page uses only two active rows out of thousands of rows
        // of capacity, so the projected full-page need saturates the
        // 32x-per-event growth bound instead of merely doubling.
        try testing.expectEqual(
            original_cap * 32,
            page.capacity.grapheme_bytes,
        );

        // All cell and grapheme content is preserved by the growth.
        try testing.expectEqual(
            @as(usize, s.rows * s.cols),
            page.graphemeCount(),
        );
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x + 1)),
                    rac.cell.content.codepoint.data,
                );
                const cps = page.lookupGrapheme(rac.cell).?;
                try testing.expectEqual(@as(usize, 2), cps.len);
                try testing.expectEqual(@as(u21, 0x0301), cps[0]);
                try testing.expectEqual(@as(u21, 0x0302), cps[1]);
            }
        }
    }
}

test "PageList increaseCapacity to increase hyperlinks" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();

    const original_cap = s.pages.first.?.capacity().hyperlink_bytes;

    {
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
    }

    _ = try s.increaseCapacity(s.pages.first.?, .hyperlink_bytes);

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        try testing.expectEqual(original_cap * 2, page.capacity.hyperlink_bytes);

        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x)),
                    rac.cell.content.codepoint.data,
                );
            }
        }
    }
}

test "PageList increaseCapacity to increase string_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();

    const original_cap = s.pages.first.?.capacity().string_bytes;

    {
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
    }

    _ = try s.increaseCapacity(s.pages.first.?, .string_bytes);

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        try testing.expectEqual(original_cap * 2, page.capacity.string_bytes);

        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x)),
                    rac.cell.content.codepoint.data,
                );
            }
        }
    }
}

test "PageList increaseCapacity tracked pins" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();

    // Create a tracked pin on the first page
    const tracked = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 1 } }).?);
    defer s.untrackPin(tracked);

    const old_node = s.pages.first.?;
    try testing.expectEqual(old_node, tracked.node);

    // Increase capacity
    const new_node = try s.increaseCapacity(s.pages.first.?, .styles);

    // Pin should now point to the new node
    try testing.expectEqual(new_node, tracked.node);
    try testing.expectEqual(@as(size.CellCountInt, 1), tracked.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), tracked.y);
}

test "PageList increaseCapacity returns OutOfSpace at max capacity" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();

    // Keep increasing styles capacity until we get OutOfSpace
    const max_styles = std.math.maxInt(size.StyleCountInt);
    while (true) {
        _ = s.increaseCapacity(
            s.pages.first.?,
            .styles,
        ) catch |err| {
            // Before OutOfSpace, we should have reached maxInt
            try testing.expectEqual(error.OutOfSpace, err);
            try testing.expectEqual(max_styles, s.pages.first.?.capacity().styles);
            break;
        };
    }
}

test "PageList increaseCapacity after col shrink" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 2, .max_size = 0 });
    defer s.deinit();

    // Shrink columns
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(5, s.cols);

    {
        const page = s.pages.first.?.page();
        try testing.expectEqual(5, page.size.cols);
        try testing.expect(page.capacity.cols >= 10);
    }

    // Increase capacity
    _ = try s.increaseCapacity(s.pages.first.?, .styles);

    {
        const page = s.pages.first.?.page();
        // size.cols should still be 5, not reverted to capacity.cols
        try testing.expectEqual(5, page.size.cols);
        try testing.expectEqual(5, s.cols);
    }
}

test "PageList increaseCapacity multi-page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow to create a second page
    const page1_node = s.pages.last.?;
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1_node.capacity().rows - page1_node.rows()) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);

    // Now we have two pages
    try testing.expect(s.pages.first != s.pages.last);
    const page2_node = s.pages.last.?;

    const page1_styles_cap = s.pages.first.?.capacity().styles;
    const page2_styles_cap = page2_node.capacity().styles;

    // Increase capacity on the first page only
    _ = try s.increaseCapacity(s.pages.first.?, .styles);

    // First page capacity should be doubled
    try testing.expectEqual(
        page1_styles_cap * 2,
        s.pages.first.?.capacity().styles,
    );

    // Second page should be unchanged
    try testing.expectEqual(
        page2_styles_cap,
        s.pages.last.?.capacity().styles,
    );
}

test "PageList increaseCapacity preserves dirty flag" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 4, .max_size = 0 });
    defer s.deinit();

    // Set page dirty flag and mark some rows as dirty
    const page = s.pages.first.?.page();
    page.dirty = true;

    const rows = page.rows.ptr(page.memory);
    rows[0].dirty = true;
    rows[1].dirty = false;
    rows[2].dirty = true;
    rows[3].dirty = false;

    // Increase capacity
    const new_node = try s.increaseCapacity(s.pages.first.?, .styles);

    // The page dirty flag should be preserved
    try testing.expect(new_node.page().dirty);

    // Row dirty flags should be preserved
    const new_rows = new_node.page().rows.ptr(new_node.page().memory);
    try testing.expect(new_rows[0].dirty);
    try testing.expect(!new_rows[1].dirty);
    try testing.expect(new_rows[2].dirty);
    try testing.expect(!new_rows[3].dirty);
}

test "PageList resize (no reflow) more rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), totalRows(&s));

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 2 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .rows = 10, .reflow = false });
    try testing.expectEqual(@as(usize, 10), s.rows);
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    // Our cursor should not move because we have no scrollback so
    // we just grew.
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 2,
    } }, s.pointFromPin(.active, p.*).?);

    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}

test "PageList resize (no reflow) more rows with history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3 });
    defer s.deinit();
    try growRows(&s, 50);
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 50,
        } }, pt);
    }

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 2 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 53), totalRows(&s));

    // Our cursor should move since it's in the scrollback
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 4,
    } }, s.pointFromPin(.active, p.*).?);

    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 48,
        } }, pt);
    }
}

test "PageList resize (no reflow) less rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    // This is required for our writing below to work
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Write into all rows so we don't get trim behavior
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }

    // Resize
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 10), totalRows(&s));
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }
}

test "PageList resize (no reflow) one rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    // This is required for our writing below to work
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Write into all rows so we don't get trim behavior
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }

    // Resize
    try s.resize(.{ .rows = 1, .reflow = false });
    try testing.expectEqual(@as(usize, 1), s.rows);
    try testing.expectEqual(@as(usize, 10), totalRows(&s));
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 9,
        } }, pt);
    }
}

test "PageList resize (no reflow) less rows cursor on bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    // This is required for our writing below to work
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Write into all rows so we don't get trim behavior
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 9 } }).?);
    defer s.untrackPin(p);
    {
        const cursor = s.pointFromPin(.active, p.*).?.active;
        const get = s.getCell(.{ .active = .{
            .x = cursor.x,
            .y = cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 9), get.cell.content.codepoint.data);
    }

    // Resize
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    // Our cursor should move since it's in the scrollback
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 4,
    } }, s.pointFromPin(.active, p.*).?);

    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }
}

test "PageList resize (no reflow) less rows cursor in scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    // This is required for our writing below to work
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Write into all rows so we don't get trim behavior
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 2 } }).?);
    defer s.untrackPin(p);
    {
        const cursor = s.pointFromPin(.active, p.*).?.active;
        const get = s.getCell(.{ .active = .{
            .x = cursor.x,
            .y = cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 2), get.cell.content.codepoint.data);
    }

    // Resize
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    // Our cursor should move since it's in the scrollback
    try testing.expect(s.pointFromPin(.active, p.*) == null);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 2,
    } }, s.pointFromPin(.screen, p.*).?);

    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }
}

test "PageList resize (no reflow) less rows trims blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 5, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Write codepoint into first line
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }

    // Fill remaining lines with a background color
    for (1..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 0 } }).?);
    defer s.untrackPin(p);
    {
        const cursor = s.pointFromPin(.active, p.*).?.active;
        const get = s.getCell(.{ .active = .{
            .x = cursor.x,
            .y = cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 'A'), get.cell.content.codepoint.data);
    }

    // Resize
    try s.resize(.{ .rows = 2, .reflow = false });
    try testing.expectEqual(@as(usize, 2), s.rows);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    // Our cursor should not move since we trimmed
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);

    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}

test "PageList resize (no reflow) less rows trims blank lines cursor in blank line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 5, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Write codepoint into first line
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }

    // Fill remaining lines with a background color
    for (1..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }

    // Put a tracked pin in a blank line
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 3 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .rows = 2, .reflow = false });
    try testing.expectEqual(@as(usize, 2), s.rows);
    try testing.expectEqual(@as(usize, 4), totalRows(&s));

    // Our cursor should not move since we trimmed
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 1,
    } }, s.pointFromPin(.active, p.*).?);
}

test "PageList resize (no reflow) less rows trims blank lines erases pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 100, .rows = 5, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Resize to take up two pages
    {
        const rows = page.capacity.rows + 10;
        try s.resize(.{ .rows = rows, .reflow = false });
        try testing.expectEqual(@as(usize, 2), s.totalPages());
    }

    // Write codepoint into first line
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }

    // Resize down. Every row except the first is blank so we
    // should erase the second page.
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 5), totalRows(&s));
    try testing.expectEqual(@as(usize, 1), s.totalPages());
}

test "PageList resize (no reflow) more rows extends blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Write codepoint into first line
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }

    // Fill remaining lines with a background color
    for (1..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }

    // Resize
    try s.resize(.{ .rows = 7, .reflow = false });
    try testing.expectEqual(@as(usize, 7), s.rows);
    try testing.expectEqual(@as(usize, 7), totalRows(&s));
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}

test "PageList resize (no reflow) more rows contains viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // When the rows are increased we need to make sure that the viewport
    // doesn't end up below the active area if it's currently in pin mode.

    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_size = 1 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);

    // Make it so we have scrollback
    _ = try s.grow();

    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 6), totalRows(&s));

    // Set viewport above active by scrolling up one.
    s.scroll(.{ .delta_row = -1 });
    // The viewport should be a pin now.
    try testing.expectEqual(Viewport.top, s.viewport);

    // Resize
    try s.resize(.{ .rows = 7, .reflow = false });
    try testing.expectEqual(@as(usize, 7), s.rows);
    try testing.expectEqual(@as(usize, 7), totalRows(&s));

    // Question: maybe the viewport should actually be in the active
    // here and not pinned to the top.
    try testing.expectEqual(Viewport.top, s.viewport);
}

test "PageList resize (no reflow) less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    // Resize
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}

test "PageList resize (no reflow) less cols pin in trimmed cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 8, .y = 2 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }

    try testing.expectEqual(point.Point{ .active = .{
        .x = 4,
        .y = 2,
    } }, s.pointFromPin(.active, p.*).?);
}

test "PageList resize (no reflow) less cols clears graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    // Add a grapheme.
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(9, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
        try page.appendGrapheme(rac.row, rac.cell, 'A');
    }
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());

    // Resize
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    var it = s.pageIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |chunk| {
        try testing.expectEqual(@as(usize, 0), chunk.node.page().graphemeCount());
    }
}

test "PageList resize (no reflow) more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_size = 0 });
    defer s.deinit();

    // Resize
    try s.resize(.{ .cols = 10, .reflow = false });
    try testing.expectEqual(@as(usize, 10), s.cols);
    try testing.expectEqual(@as(usize, 3), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 10), cells.len);
    }
}

test "PageList resize (no reflow) more cols with spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 3, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_head,
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 3, .reflow = false });
    try testing.expectEqual(@as(usize, 3), s.cols);
    try testing.expectEqual(@as(usize, 3), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            // try testing.expect(!rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
    }
}

// Regression test for fuzz crash. When we shrink cols and then
// grow back, the page retains capacity from the original size so the grow
// takes the fast path (just bumps page.size.cols). If any row has a
// spacer_head at the old last column, that cell is no longer at the end
// of the wider row, violating page integrity.
test "PageList resize (no reflow) grow cols fast path with spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_size = 0 });
    defer s.deinit();

    // Shrink to 5 cols. The page keeps capacity for 10 cols.
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);

    // Place a spacer_head at the last column (col 4) on two rows
    // to simulate a wide character that didn't fit at the right edge.
    {
        const page = s.pages.first.?.page();

        // Row 0: 'x' at col 0..3, spacer_head at col 4, wrap = true
        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(4, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_head,
            };
            rac.row.wrap = true;
        }

        // Row 1: spacer_head at col 4, wrap = true
        {
            const rac = page.getRowAndCell(4, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_head,
            };
            rac.row.wrap = true;
        }
    }

    // Grow back to 10 cols. This must not leave stale spacer_head
    // cells at col 4 (which is no longer the last column).
    try s.resize(.{ .cols = 10, .reflow = false });
    try testing.expectEqual(@as(usize, 10), s.cols);

    // Verify the old spacer_head positions are now narrow.
    {
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(4, 0);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(!rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(4, 1);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(!rac.row.wrap);
        }
    }
}

// This test is a bit convoluted so I want to explain: what we are trying
// to verify here is that when we increase cols such that our rows per page
// shrinks, we don't fragment our rows across many pages because this ends
// up wasting a lot of memory.
//
// This is particularly important for alternate screen buffers where we
// don't have scrollback so our max size is very small. If we don't do this,
// we end up pruning our pages and that causes resizes to fail!
test "PageList resize (no reflow) more cols forces less rows per page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // This test requires initially that our rows fit into one page.
    const cols: size.CellCountInt = 5;
    const rows: size.CellCountInt = 150;
    try testing.expect((try std_capacity.adjust(.{ .cols = cols })).rows >= rows);
    var s = try init(alloc, .{ .cols = cols, .rows = rows, .max_size = 0 });
    defer s.deinit();

    // Then we need to resize our cols so that our rows per page shrinks.
    // This will force our resize to split our rows across two pages.
    {
        const new_cols = new_cols: {
            var new_cols: size.CellCountInt = 50;
            var cap = try std_capacity.adjust(.{ .cols = new_cols });
            while (cap.rows >= rows) {
                new_cols += 50;
                cap = try std_capacity.adjust(.{ .cols = new_cols });
            }

            break :new_cols new_cols;
        };
        try s.resize(.{ .cols = new_cols, .reflow = false });
        try testing.expectEqual(@as(usize, new_cols), s.cols);
        try testing.expectEqual(@as(usize, rows), totalRows(&s));
    }

    // Every page except the last should be full
    {
        var it = s.pages.first;
        while (it) |page| : (it = page.next) {
            if (page == s.pages.last.?) break;
            try testing.expectEqual(page.capacity().rows, page.rows());
        }
    }

    // Now we need to resize again to a col size that further shrinks
    // our last capacity.
    {
        const page = s.pages.first.?.page();
        try testing.expect(page.size.rows == page.capacity.rows);
        const new_cols = new_cols: {
            var new_cols = page.size.cols + 50;
            var cap = try std_capacity.adjust(.{ .cols = new_cols });
            while (cap.rows >= page.size.rows) {
                new_cols += 50;
                cap = try std_capacity.adjust(.{ .cols = new_cols });
            }

            break :new_cols new_cols;
        };

        try s.resize(.{ .cols = new_cols, .reflow = false });
        try testing.expectEqual(@as(usize, new_cols), s.cols);
        try testing.expectEqual(@as(usize, rows), totalRows(&s));
    }

    // Every page except the last should be full
    {
        var it = s.pages.first;
        while (it) |page| : (it = page.next) {
            if (page == s.pages.last.?) break;
            try testing.expectEqual(page.capacity().rows, page.rows());
        }
    }
}

test "PageList resize (no reflow) less cols then more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_size = 0 });
    defer s.deinit();

    // Resize less
    try s.resize(.{ .cols = 2, .reflow = false });
    try testing.expectEqual(@as(usize, 2), s.cols);

    // Resize
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 3), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}

test "PageList resize (no reflow) less rows and cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    // Resize less
    try s.resize(.{ .cols = 5, .rows = 7, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 7), s.rows);

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}

test "PageList resize less rows and cols cursor at bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();

    const cursor_pin = try s.trackPin(s.pin(.{ .active = .{
        .x = 0,
        .y = s.rows - 1,
    } }).?);
    defer s.untrackPin(cursor_pin);

    // Shrink both axes such that the original cursor.y is strictly past the
    // new row count, so resizeWithoutReflow leaves self.rows < c.y + 1.
    try s.resize(.{
        .cols = 79,
        .rows = 20,
        .reflow = true,
        .cursor = .{ .x = 0, .y = 23, .pin = cursor_pin },
    });
    try testing.expectEqual(@as(usize, 79), s.cols);
    try testing.expectEqual(@as(usize, 20), s.rows);

    // remaining_rows saturates to 0, so the cursor lands on the new bottom row.
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = s.rows - 1,
    } }, s.pointFromPin(.active, cursor_pin.*).?);
}

test "PageList resize less rows and cols cursor near top pushed to scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Fill every active row with non-blank content so that shrinking rows
    // can't trim trailing blank lines and instead pushes the top rows into
    // scrollback.
    {
        var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            const cells = p.node.page().getCells(rac.row);
            for (cells, 0..) |*cell, x| cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast('A' + (x % 26)) } },
            };
        }
    }

    // Cursor near the top of the active area. After we shrink rows the active
    // area top moves down past this pin, so it ends up in scrollback.
    const cursor_pin = try s.trackPin(s.pin(.{ .active = .{
        .x = 0,
        .y = 0,
    } }).?);
    defer s.untrackPin(cursor_pin);

    // Shrink both axes with reflow. resizeWithoutReflow shrinks self.rows
    // first, leaving the cursor pin above the new active area, then resizeCols
    // walks .left_up from the cursor pin toward the active-area top.
    try s.resize(.{
        .cols = 79,
        .rows = 20,
        .reflow = true,
        .cursor = .{ .x = 0, .y = 0, .pin = cursor_pin },
    });
    try testing.expectEqual(@as(usize, 79), s.cols);
    try testing.expectEqual(@as(usize, 20), s.rows);

    // The active area is anchored to the bottom, so shrinking rows pushed the
    // top-of-screen cursor into scrollback: it no longer resolves to an
    // active-area coordinate, but it remains a valid screen pin.
    try testing.expect(s.pointFromPin(.active, cursor_pin.*) == null);
    try testing.expect(s.pointFromPin(.screen, cursor_pin.*) != null);

    // Integrity must hold after the resize.
    s.assertIntegrity();
}

test "PageList resize (no reflow) more rows and less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    // Resize less
    try s.resize(.{ .cols = 5, .rows = 20, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 20), s.rows);
    try testing.expectEqual(@as(usize, 20), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}

test "PageList resize more rows and cols doesn't fit in single std page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    // Resize to a size that requires more than one page to fit our rows.
    const new_cols = 600;
    const new_rows = 600;
    const cap = try std_capacity.adjust(.{ .cols = new_cols });
    try testing.expect(cap.rows < new_rows);

    try s.resize(.{ .cols = new_cols, .rows = new_rows, .reflow = true });
    try testing.expectEqual(@as(usize, new_cols), s.cols);
    try testing.expectEqual(@as(usize, new_rows), s.rows);
    try testing.expectEqual(@as(usize, new_rows), totalRows(&s));
}

test "PageList resize (no reflow) empty screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_size = 0 });
    defer s.deinit();

    // Resize
    try s.resize(.{ .cols = 10, .rows = 10, .reflow = false });
    try testing.expectEqual(@as(usize, 10), s.cols);
    try testing.expectEqual(@as(usize, 10), s.rows);
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 10), cells.len);
    }
}

test "PageList resize (no reflow) more cols forces smaller cap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // We want a cap that forces us to have less rows
    const cap = try std_capacity.adjust(.{ .cols = 100 });
    const cap2 = try std_capacity.adjust(.{ .cols = 500 });
    try testing.expectEqual(@as(size.CellCountInt, 500), cap2.cols);
    try testing.expect(cap2.rows < cap.rows);

    // Create initial cap, fits in one page
    var s = try init(alloc, .{ .cols = cap.cols, .rows = cap.rows });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
            };
        }
    }

    // Resize to our large cap
    const rows = totalRows(&s);
    try s.resize(.{ .cols = cap2.cols, .reflow = false });

    // Our total rows should be the same, and contents should be the same.
    try testing.expectEqual(rows, totalRows(&s));
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, cap2.cols), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint.data);
    }
}

test "PageList resize (no reflow) more rows adds blank rows if cursor at bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer s.deinit();

    // Grow to 5 total rows, simulating 3 active + 2 scrollback
    try growRows(&s, 2);
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..totalRows(&s)) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }

    // Active should be on row 3
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = s.rows - 2 } }).?);
    defer s.untrackPin(p);
    const original_cursor = s.pointFromPin(.active, p.*).?.active;
    {
        const get = s.getCell(.{ .active = .{
            .x = original_cursor.x,
            .y = original_cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 3), get.cell.content.codepoint.data);
    }

    // Resize
    try resizeWithoutReflow(&s, .{
        .rows = 10,
        .reflow = false,
        .cursor = .{ .x = 0, .y = s.rows - 2 },
    });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 10), s.rows);

    // Our cursor should not change
    try testing.expectEqual(original_cursor, s.pointFromPin(.active, p.*).?.active);

    // 12 because we have our 10 rows in the active + 2 in the scrollback
    // because we're preserving the cursor.
    try testing.expectEqual(@as(usize, 12), totalRows(&s));

    // Active should be at the same place it was.
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }

    // Go through our active, we should get only 3,4,5
    for (0..3) |y| {
        const get = s.getCell(.{ .active = .{ .y = @intCast(y) } }).?;
        const expected: u21 = @intCast(y + 2);
        try testing.expectEqual(expected, get.cell.content.codepoint.data);
    }
}

test "PageList resize reflow more cols no wrapped rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 10, .reflow = true });
    try testing.expectEqual(@as(usize, 10), s.cols);
    try testing.expectEqual(@as(usize, 3), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 10), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint.data);
    }
}

test "PageList resize reflow more cols wrapped rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 4, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        if (y % 2 == 0) {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        } else {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }

        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), totalRows(&s));

    // Active should still be on top
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    {
        // First row should be unwrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 4), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint.data);
        try testing.expectEqual(@as(u21, 'A'), cells[2].content.codepoint.data);
    }
}

test "PageList resize reflow invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 4 });
    defer s.deinit();
    try growRows(&s, 20);

    const page = s.pages.last.?.page();
    for (0..s.rows) |y| {
        if (y % 2 == 0) {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        } else {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }

        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
            };
        }
    }

    // Scroll to a pinned viewport in history
    const pin_y = 10;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Resize with reflow - unwrapping rows changes total_rows
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);

    // Verify scrollbar cache was invalidated during reflow
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 5,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList resize reflow more cols creates multiple pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // We want a wide viewport so our row limit is rather small. This will
    // force the reflow below to create multiple pages, which we assert.
    const cap = cap: {
        var current: size.CellCountInt = 100;
        while (true) : (current += 100) {
            const cap = try std_capacity.adjust(.{ .cols = current });
            if (cap.rows < 100) break :cap cap;
        }
        unreachable;
    };

    var s = try init(alloc, .{ .cols = cap.cols, .rows = cap.rows });
    defer s.deinit();

    // Wrap every other row so every line is wrapped for reflow
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..s.rows) |y| {
            if (y % 2 == 0) {
                const rac = page.getRowAndCell(0, y);
                rac.row.wrap = true;
            } else {
                const rac = page.getRowAndCell(0, y);
                rac.row.wrap_continuation = true;
            }

            const rac = page.getRowAndCell(0, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
            };
        }
    }

    // Resize
    const newcap = try cap.adjust(.{ .cols = cap.cols + 100 });
    try testing.expect(newcap.rows < cap.rows);
    try s.resize(.{ .cols = newcap.cols, .reflow = true });
    try testing.expectEqual(@as(usize, newcap.cols), s.cols);
    try testing.expectEqual(@as(usize, cap.rows), totalRows(&s));

    {
        var count: usize = 0;
        var it = s.pages.first;
        while (it) |page| : (it = page.next) {
            count += 1;

            // All pages should have the new capacity
            try testing.expectEqual(newcap.cols, page.capacity().cols);
            try testing.expectEqual(newcap.rows, page.capacity().rows);
        }

        // We should have more than one page, meaning we created at least
        // one page. This is the critical aspect of this test so if this
        // ever goes false we need to adjust this test.
        try testing.expect(count > 1);
    }
}

test "PageList resize reflow more cols wrap across page boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow to the capacity of the first page.
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try growRows(&s, 1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
    }

    // At this point, we have some rows on the first page, and some on the second.
    // We can now wrap across the boundary condition.
    {
        const page = s.pages.first.?.page();
        const y = page.size.rows - 1;
        {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        const page2 = s.pages.last.?.page();
        const y = 0;
        {
            const rac = page2.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page2.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // PageList.diagram ->
    //
    //       +--+ = PAGE 0
    //   ... :  :
    //      +-----+ ACTIVE
    // 15744 |  | | 0
    // 15745 |  | | 1
    // 15746 |  | | 2
    // 15747 |  | | 3
    // 15748 |  | | 4
    // 15749 |  | | 5
    // 15750 |  | | 6
    // 15751 |  | | 7
    // 15752 |01… | 8
    //       +--+ :
    //       +--+ : = PAGE 1
    //     0 …01| | 9
    //       +--+ :
    //      +-----+

    // We expect one fewer rows since we unwrapped a row.
    const end_rows = totalRows(&s) - 1;

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, end_rows), totalRows(&s));

    // PageList.diagram ->
    //
    //      +----+ = PAGE 0
    //  ... :    :
    //      +----+
    //      +----+ = PAGE 1
    //  ... :    :
    //     +-------+ ACTIVE
    // 6272 |    | | 0
    // 6273 |    | | 1
    // 6274 |    | | 2
    // 6275 |    | | 3
    // 6276 |    | | 4
    // 6277 |    | | 5
    // 6278 |    | | 6
    // 6279 |    | | 7
    // 6280 |    | | 8
    // 6281 |0101| | 9
    //      +----+ :
    //     +-------+

    {
        // PAGE 1 ROW 6280, ACTIVE 8
        const p = s.pin(.{ .active = .{ .y = 8 } }).?;
        const row = p.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);

        const cells = p.cells(.all);
        try testing.expect(!cells[0].hasText());
        try testing.expect(!cells[1].hasText());
        try testing.expect(!cells[2].hasText());
        try testing.expect(!cells[3].hasText());
    }
    {
        // PAGE 1 ROW 6281, ACTIVE 9
        const p = s.pin(.{ .active = .{ .y = 9 } }).?;
        const row = p.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);

        const cells = p.cells(.all);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
        try testing.expectEqual(@as(u21, 1), cells[1].content.codepoint.data);
        try testing.expectEqual(@as(u21, 0), cells[2].content.codepoint.data);
        try testing.expectEqual(@as(u21, 1), cells[3].content.codepoint.data);
    }
}

test "PageList resize reflow more cols wrap across page boundary cursor in second page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow to the capacity of the first page.
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try growRows(&s, 1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
    }

    // At this point, we have some rows on the first page, and some on the second.
    // We can now wrap across the boundary condition.
    {
        const page = s.pages.first.?.page();
        const y = page.size.rows - 1;
        {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        const page2 = s.pages.last.?.page();
        const y = 0;
        {
            const rac = page2.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page2.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Put a tracked pin in wrapped row on the last page
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 9 } }).?);
    defer s.untrackPin(p);
    try testing.expect(p.node == s.pages.last.?);

    // We expect one fewer rows since we unwrapped a row.
    const end_rows = totalRows(&s) - 1;

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, end_rows), totalRows(&s));

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 9,
    } }, s.pointFromPin(.active, p.*).?);

    {
        const p2 = s.pin(.{ .active = .{ .y = 9 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(!row.wrap);

        const cells = p2.cells(.all);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
        try testing.expectEqual(@as(u21, 1), cells[1].content.codepoint.data);
        try testing.expectEqual(@as(u21, 0), cells[2].content.codepoint.data);
        try testing.expectEqual(@as(u21, 1), cells[3].content.codepoint.data);
    }
}

test "PageList resize reflow less cols wrap across page boundary cursor in second page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 10 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow to the capacity of the first page.
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try growRows(&s, 5);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
    }

    // At this point, we have some rows on the first page, and some on the second.
    // We can now wrap across the boundary condition.
    {
        const page = s.pages.first.?.page();
        const y = page.size.rows - 1;
        {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        const page2 = s.pages.last.?.page();
        const y = 0;
        {
            const rac = page2.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page2.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Put a tracked pin in wrapped row on the last page
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 2, .y = 5 } }).?);
    defer s.untrackPin(p);
    try testing.expect(p.node == s.pages.last.?);
    try testing.expect(p.y == 0);

    // PageList.diagram ->
    //
    //      +-----+ = PAGE 0
    //  ... :     :
    //     +--------+ ACTIVE
    // 7892 |     | | 0
    // 7893 |     | | 1
    // 7894 |     | | 2
    // 7895 |     | | 3
    // 7896 |01234… | 4
    //      +-----+ :
    //      +-----+ : = PAGE 1
    //    0 …01234| | 5
    //      :  ^  : : = PIN 0
    //    1 |     | | 6
    //    2 |     | | 7
    //    3 |     | | 8
    //    4 |     | | 9
    //      +-----+ :
    //     +--------+

    // Resize
    try s.resize(.{
        .cols = 4,
        .reflow = true,
        .cursor = .{ .x = 2, .y = 5 },
    });
    try testing.expectEqual(@as(usize, 4), s.cols);

    // PageList.diagram ->
    //
    //      +----+ = PAGE 0
    //  ... :    :
    //     +-------+ ACTIVE
    // 7892 |    | | 0
    // 7893 |    | | 1
    // 7894 |    | | 2
    // 7895 |    | | 3
    // 7896 |0123… | 4
    // 7897 …4012… | 5
    //      :   ^: : = PIN 0
    // 7898 …3400| | 6
    // 7899 |    | | 7
    // 7900 |    | | 8
    // 7901 |    | | 9
    //      +----+ :
    //     +-------+

    // Our cursor should remain on the same cell
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 5,
    } }, s.pointFromPin(.active, p.*).?);

    {
        // PAGE 0 ROW 7895, ACTIVE 3
        const p2 = s.pin(.{ .active = .{ .y = 3 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);

        const cells = p2.cells(.all);
        try testing.expect(!cells[0].hasText());
        try testing.expect(!cells[1].hasText());
        try testing.expect(!cells[2].hasText());
        try testing.expect(!cells[3].hasText());
    }
    {
        // PAGE 0 ROW 7896, ACTIVE 4
        const p2 = s.pin(.{ .active = .{ .y = 4 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(row.wrap);
        try testing.expect(!row.wrap_continuation);

        const cells = p2.cells(.all);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
        try testing.expectEqual(@as(u21, 1), cells[1].content.codepoint.data);
        try testing.expectEqual(@as(u21, 2), cells[2].content.codepoint.data);
        try testing.expectEqual(@as(u21, 3), cells[3].content.codepoint.data);
    }
    {
        // PAGE 0 ROW 7897, ACTIVE 5
        const p2 = s.pin(.{ .active = .{ .y = 5 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(row.wrap);
        try testing.expect(row.wrap_continuation);

        const cells = p2.cells(.all);
        try testing.expectEqual(@as(u21, 4), cells[0].content.codepoint.data);
        try testing.expectEqual(@as(u21, 0), cells[1].content.codepoint.data);
        try testing.expectEqual(@as(u21, 1), cells[2].content.codepoint.data);
        try testing.expectEqual(@as(u21, 2), cells[3].content.codepoint.data);
    }
    {
        // PAGE 0 ROW 7898, ACTIVE 6
        const p2 = s.pin(.{ .active = .{ .y = 6 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(row.wrap_continuation);

        const cells = p2.cells(.all);
        try testing.expectEqual(@as(u21, 3), cells[0].content.codepoint.data);
        try testing.expectEqual(@as(u21, 4), cells[1].content.codepoint.data);
    }
    {
        // PAGE 0 ROW 7899, ACTIVE 7
        const p2 = s.pin(.{ .active = .{ .y = 7 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);

        const cells = p2.cells(.all);
        try testing.expect(!cells[0].hasText());
        try testing.expect(!cells[1].hasText());
        try testing.expect(!cells[2].hasText());
        try testing.expect(!cells[3].hasText());
    }
}

test "PageList resize reflow more cols cursor in wrapped row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 4, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 1 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), totalRows(&s));

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}

test "PageList resize reflow more cols cursor in not wrapped row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 4, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), totalRows(&s));

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 1,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}

test "PageList resize reflow more cols cursor in wrapped row that isn't unwrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 4, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap = true;
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        {
            const rac = page.getRowAndCell(0, 2);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 2);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 2 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), totalRows(&s));

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 1,
        .y = 1,
    } }, s.pointFromPin(.active, p.*).?);
}

test "PageList resize reflow more cols no reflow preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 4, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 1);
        rac.row.semantic_prompt = .prompt;
    }

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 1);
        try testing.expect(rac.row.semantic_prompt == .prompt);
    }
}

test "PageList resize reflow exceeds hyperlink memory forcing capacity increase" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow to the capacity of the first page and add
    // one more row so that we have two pages total.
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try growRows(&s, 1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());

        // We now have two pages.
        try std.testing.expect(s.pages.first.? != s.pages.last.?);
        try std.testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }

    // We use almost all string alloc capacity with a hyperlink in the final
    // row of the first page, and do the same on the first row of the second
    // page. We also mark the row as wrapped so that when we resize with more
    // cols the row unwraps and we have a single row that requires almost two
    // times the base string alloc capacity.
    //
    // This forces the reflow to increase capacity.
    //
    //  +--+ = PAGE 0
    //  :  :
    //  | X… <- where X is hyperlinked with almost all string cap.
    //  +--+
    //  +--+ = PAGE 1
    //  …X | <- X here also almost hits string cap with a hyperlink.
    //  +--+

    // Almost hit string alloc cap in bottom right of first page.
    // Mark the final row as wrapped.
    {
        const page = s.pages.first.?.page();
        const id = try page.insertHyperlink(.{
            .id = .{ .implicit = 0 },
            .uri = "a" ** (pagepkg.string_bytes_default - 1),
        });
        const rac = page.getRowAndCell(page.size.cols - 1, page.size.rows - 1);
        rac.row.wrap = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'X' } },
        };
        try page.setHyperlink(rac.row, rac.cell, id);
        try std.testing.expectError(
            error.StringsOutOfMemory,
            page.insertHyperlink(.{
                .id = .{ .implicit = 1 },
                .uri = "AAAAAAAAAAAAAAAAAAAAAAAAAA",
            }),
        );
    }

    // Almost hit string alloc cap in top left of second page.
    // Mark the first row as a wrap continuation.
    {
        const page = s.pages.last.?.page();
        const id = try page.insertHyperlink(.{
            .id = .{ .implicit = 1 },
            .uri = "a" ** (pagepkg.string_bytes_default - 1),
        });
        const rac = page.getRowAndCell(0, 0);
        rac.row.wrap_continuation = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'X' } },
        };
        try page.setHyperlink(rac.row, rac.cell, id);
        try std.testing.expectError(
            error.StringsOutOfMemory,
            page.insertHyperlink(.{
                .id = .{ .implicit = 2 },
                .uri = "AAAAAAAAAAAAAAAAAAAAAAAAAA",
            }),
        );
    }

    // Resize to 1 column wider, unwrapping the row.
    try s.resize(.{ .cols = s.cols + 1, .reflow = true });
}

test "PageList resize reflow hyperlink dupe string alloc chunk rounding" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow to the capacity of the first page and add
    // one more row so that we have two pages total.
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try growRows(&s, 1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());

        // We now have two pages.
        try std.testing.expect(s.pages.first.? != s.pages.last.?);
        try std.testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }

    // The string allocator hands out 32-byte chunks and every allocation
    // is rounded up to the chunk size independently. Duping a hyperlink
    // during reflow allocates the URI and the explicit ID separately, so
    // two separate allocations can require one more chunk than a single
    // combined allocation of the same total byte length.
    //
    // We arrange for the reflow target page to have exactly two free
    // chunks (64 bytes) remaining when a hyperlink with a 33-byte URI
    // (2 chunks) and a 31-byte explicit ID (1 chunk) is reflowed into
    // it. The combined byte length (64 bytes -> 2 chunks) fits, but the
    // separate allocations (3 chunks) do not, so the reflow must grow
    // the string capacity rather than panic or drop the hyperlink.
    //
    // The two hyperlinked cells are joined as a single wrapped row so
    // that they are always reflowed into the same target page.
    //
    //  +--+ = PAGE 0
    //  :  :
    //  | A… <- A is hyperlinked with all but 64 bytes of string cap.
    //  +--+
    //  +--+ = PAGE 1
    //  …B | <- B is hyperlinked with a 33-byte URI and 31-byte ID.
    //  +--+

    const uri_a = "a" ** (pagepkg.string_bytes_default - 64);
    const uri_b = "b" ** 33;
    const id_b = "i" ** 31;

    // Hyperlink A in the bottom right of the first page. Mark the final
    // row as wrapped.
    {
        const page = s.pages.first.?.page();
        const id = try page.insertHyperlink(.{
            .id = .{ .implicit = 0 },
            .uri = uri_a,
        });
        const rac = page.getRowAndCell(page.size.cols - 1, page.size.rows - 1);
        rac.row.wrap = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
        try page.setHyperlink(rac.row, rac.cell, id);

        // Sanity check the chunk math: the remaining 64 bytes fit as a
        // single allocation but not as the two separate allocations that
        // inserting (or duping) hyperlink B performs.
        const buf = try page.string_alloc.alloc(u8, page.memory, 64);
        page.string_alloc.free(page.memory, buf);
        try std.testing.expectError(
            error.StringsOutOfMemory,
            page.insertHyperlink(.{
                .id = .{ .explicit = id_b },
                .uri = uri_b,
            }),
        );
    }

    // Hyperlink B in the top left of the second page. Mark the first
    // row as a wrap continuation.
    {
        const page = s.pages.last.?.page();
        const id = try page.insertHyperlink(.{
            .id = .{ .explicit = id_b },
            .uri = uri_b,
        });
        const rac = page.getRowAndCell(0, 0);
        rac.row.wrap_continuation = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'B' } },
        };
        try page.setHyperlink(rac.row, rac.cell, id);
    }

    // Resize to 1 column wider, unwrapping the row.
    try s.resize(.{ .cols = s.cols + 1, .reflow = true });

    // Both hyperlinks must have survived the reflow intact.
    var found: usize = 0;
    var node_it = s.pages.first;
    while (node_it) |node| : (node_it = node.next) {
        const page = node.page();
        for (0..page.size.rows) |y| {
            for (0..page.size.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                if (!rac.cell.hyperlink) continue;
                found += 1;

                const link_id = page.lookupHyperlink(rac.cell).?;
                const entry = page.hyperlink_set.get(page.memory, link_id);
                const uri = entry.uri.slice(page.memory);
                switch (entry.id) {
                    .implicit => try testing.expectEqualStrings(uri_a, uri),
                    .explicit => |slice| {
                        try testing.expectEqualStrings(uri_b, uri);
                        try testing.expectEqualStrings(
                            id_b,
                            slice.slice(page.memory),
                        );
                    },
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 2), found);
}

test "PageList resize reflow exceeds grapheme memory forcing capacity increase" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow to the capacity of the first page and add
    // one more row so that we have two pages total.
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try growRows(&s, 1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());

        // We now have two pages.
        try std.testing.expect(s.pages.first.? != s.pages.last.?);
        try std.testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }

    // We use all grapheme alloc capacity with four maximum-sized graphemes on
    // each page. The two rows form one wrapped logical line across the page
    // boundary, so resizing wider moves all eight graphemes into one page and
    // requires almost two times the base grapheme alloc capacity.
    //
    // This forces the reflow to increase capacity.
    //
    //  +----+ = PAGE 0
    //  :  :
    //  |XXXX| <- four capped graphemes in one wrapped row.
    //  +----+
    //  +----+ = PAGE 1
    //  |XXXX| <- four more capped graphemes continue the logical line.
    //  +----+

    const suffixes: [pagepkg.grapheme_max_len]u21 = @splat('a');

    // Fill the final row of the first page and mark it as wrapped.
    {
        const page = s.pages.first.?.page();
        const y = page.size.rows - 1;
        const row = page.getRow(y);
        row.wrap = true;

        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .init('X');
            try page.setGraphemes(rac.row, rac.cell, &suffixes);
        }
        try std.testing.expectEqual(
            page.grapheme_alloc.capacityBytes(),
            page.grapheme_alloc.usedBytes(page.memory),
        );
        try std.testing.expectError(
            error.OutOfMemory,
            page.grapheme_alloc.alloc(
                u21,
                page.memory,
                16,
            ),
        );
    }

    // Fill the first row of the second page and mark it as a continuation.
    {
        const page = s.pages.last.?.page();
        const row = page.getRow(0);
        row.wrap_continuation = true;

        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .init('X');
            try page.setGraphemes(rac.row, rac.cell, &suffixes);
        }
        try std.testing.expectError(
            error.OutOfMemory,
            page.grapheme_alloc.alloc(
                u21,
                page.memory,
                16,
            ),
        );
    }

    // Resize to 1 column wider, unwrapping the row.
    try s.resize(.{ .cols = s.cols + 1, .reflow = true });
}

test "PageList resize reflow exceeds style memory forcing capacity increase" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = pagepkg.std_capacity.styles - 1, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow to the capacity of the first page and add
    // one more row so that we have two pages total.
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try growRows(&s, 1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());

        // We now have two pages.
        try std.testing.expect(s.pages.first.? != s.pages.last.?);
        try std.testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }

    // Give each cell in the final row of the first page a unique style.
    // Mark the final row as wrapped.
    {
        const page = s.pages.first.?.page();
        for (0..s.cols) |x| {
            const id = page.styles.add(
                page.memory,
                .{
                    .bg_color = .{ .rgb = .{
                        .r = @truncate(x),
                        .g = @truncate(x >> 8),
                        .b = @truncate(x >> 16),
                    } },
                },
            ) catch break;

            const rac = page.getRowAndCell(x, page.size.rows - 1);
            rac.row.wrap = true;
            rac.row.styled = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'X' } },
                .style_id = id,
            };
        }
    }

    // Do the same for the first row of the second page.
    // Mark the first row as a wrap continuation.
    {
        const page = s.pages.last.?.page();
        for (0..s.cols) |x| {
            const id = page.styles.add(
                page.memory,
                .{
                    .fg_color = .{ .rgb = .{
                        .r = @truncate(x),
                        .g = @truncate(x >> 8),
                        .b = @truncate(x >> 16),
                    } },
                },
            ) catch break;

            const rac = page.getRowAndCell(x, 0);
            rac.row.wrap_continuation = true;
            rac.row.styled = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'X' } },
                .style_id = id,
            };
        }
    }

    // Resize to twice as wide, fully unwrapping the row.
    try s.resize(.{ .cols = s.cols * 2, .reflow = true });
}

test "PageList resize reflow more cols unwrap wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_head,
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(!rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}

test "PageList resize reflow more cols unwrap wide spacer head across two rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 3, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_head,
            };
        }
        {
            const rac = page.getRowAndCell(0, 2);
            rac.row.wrap_continuation = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 2);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 3), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(3, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_head, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}

test "PageList resize reflow more cols unwrap still requires wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 3, .reflow = true });
    try testing.expectEqual(@as(usize, 3), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_head, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}

test "PageList resize reflow less cols no reflow preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 4, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.semantic_prompt = .prompt;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        {
            const p = s.pin(.{ .active = .{ .y = 1 } }).?;
            const rac = p.rowAndCell();
            try testing.expect(rac.row.wrap);
            try testing.expect(rac.row.semantic_prompt == .prompt);
        }
        {
            const p = s.pin(.{ .active = .{ .y = 2 } }).?;
            const rac = p.rowAndCell();
            try testing.expect(rac.row.semantic_prompt == .prompt);
        }
    }
}

test "PageList resize reflow less cols no reflow preserves semantic prompt on first line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 4, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 0);
        rac.row.semantic_prompt = .prompt;
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 0);
        try testing.expect(rac.row.semantic_prompt == .prompt);
    }
}

test "PageList resize reflow less cols wrap preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 4, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 0);
        rac.row.semantic_prompt = .prompt;
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 0);
        try testing.expect(rac.row.semantic_prompt == .prompt);
    }
}

test "PageList resize reflow less cols no wrapped rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        const end = 4;
        assert(end < s.cols);
        for (0..4) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 5, .reflow = true });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 3), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        for (0..4) |x| {
            var offset_copy = offset;
            offset_copy.x = @intCast(x);
            const rac = offset_copy.rowAndCell();
            const cells = offset.node.page().getCells(rac.row);
            try testing.expectEqual(@as(usize, 5), cells.len);
            try testing.expectEqual(@as(u21, @intCast(x)), cells[x].content.codepoint.data);
        }
    }
}

test "PageList resize reflow less cols wrapped rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 2 });
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

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), totalRows(&s));

    // Active moves due to scrollback
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint.data);
    }
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint.data);
    }
}

test "PageList resize reflow less cols wrapped rows with graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 2 });
    defer s.deinit();
    {
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

            const rac = page.getRowAndCell(2, y);
            try page.appendGrapheme(rac.row, rac.cell, 'A');
        }
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), totalRows(&s));

    // Active moves due to scrollback
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }

    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expect(rac.row.grapheme);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint.data);

        const cps = page.lookupGrapheme(rac.cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
        try testing.expectEqual(@as(u21, 'A'), cps[0]);
    }
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expect(rac.row.grapheme);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint.data);

        const cps = page.lookupGrapheme(rac.cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
        try testing.expectEqual(@as(u21, 'A'), cps[0]);
    }
}

test "PageList resize reflow less cols cursor in wrapped row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 2 });
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 2, .y = 1 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), totalRows(&s));

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 1,
    } }, s.pointFromPin(.active, p.*).?);
}

test "PageList resize reflow less cols wraps spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 3, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(2, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(3, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_head,
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 3, .reflow = true });
    try testing.expectEqual(@as(usize, 3), s.cols);
    try testing.expectEqual(@as(usize, 3), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}

test "PageList resize reflow less cols cursor goes to scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 2 });
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 2, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), totalRows(&s));

    // Our cursor should move to the first row
    try testing.expect(s.pointFromPin(.active, p.*) == null);
}

test "PageList resize reflow less cols cursor in unchanged row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 2 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 1,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}

test "PageList resize reflow less cols cursor in blank cell" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 6, .rows = 2 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 2, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    // Our cursor should not move
    try testing.expectEqual(point.Point{ .active = .{
        .x = 2,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}

test "PageList resize reflow less cols cursor in final blank cell" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 6, .rows = 2 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 3, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}

test "PageList resize reflow less cols cursor in wrapped blank cell" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 6, .rows = 2 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 5, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}

test "PageList resize reflow less cols blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..1) |y| {
        for (0..4) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 3), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint.data);
    }
}

test "PageList resize reflow less cols blank lines between" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        for (0..4) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        for (0..4) |x| {
            const rac = page.getRowAndCell(x, 2);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 5), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        try testing.expect(!rac.row.wrap);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint.data);
    }
}

test "PageList resize reflow less cols blank lines between no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }
    {
        const rac = page.getRowAndCell(0, 2);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'C' } },
        };
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 3), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 'C'), cells[0].content.codepoint.data);
    }
}

test "PageList resize reflow less cols cursor not on last line preserves location" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_size = 1 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Grow blank rows to push our rows back into scrollback
    try growRows(&s, 5);
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{
        .cols = 4,
        .reflow = true,

        // Important: not on last row
        .cursor = .{ .x = 1, .y = 1 },
    });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}

test "PageList resize reflow less cols no scrollback pull blank active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_size = 1 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }

    // Grow blank rows to push our rows back into scrollback
    try growRows(&s, 5);
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize with no cursor. Normally the trailing blank rows would be
    // trimmed and the active area would slide up over our history.
    try s.resize(.{
        .cols = 4,
        .reflow = true,
        .pull_scrollback = false,
    });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 10), totalRows(&s));

    // The top of the active area should not move
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}

test "PageList resize reflow less cols copy style" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // Create a style
        const style: stylepkg.Style = .{ .flags = .{ .bold = true } };
        const style_id = try page.styles.add(page.memory, style);

        for (0..s.cols - 1) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
                .style_id = style_id,
            };
            page.styles.use(page.memory, style_id);
        }

        // We're over-counted by 1 because `add` implies `use`.
        page.styles.release(page.memory, style_id);
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    while (it.next()) |offset| {
        for (0..s.cols - 1) |x| {
            var offset_copy = offset;
            offset_copy.x = @intCast(x);
            const rac = offset_copy.rowAndCell();
            const style_id = rac.cell.style_id;
            try testing.expect(style_id != 0);

            const style = offset.node.page().styles.get(
                offset.node.page().memory,
                style_id,
            );
            try testing.expect(style.flags.bold);

            const row = rac.row;
            try testing.expect(row.styled);
        }
    }
}

test "PageList resize reflow less cols to eliminate a wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 1, .reflow = true });
    try testing.expectEqual(@as(usize, 1), s.cols);
    try testing.expectEqual(@as(usize, 1), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
    }
}

test "PageList resize reflow less cols to wrap a wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 3, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(2, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_head, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}

test "PageList resize reflow less cols wide char bulk run" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 8, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // A full row of wide character pairs so the reflow takes
        // the bulk run path.
        for (0..4) |i| {
            {
                const rac = page.getRowAndCell(i * 2, 0);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(0x4E00 + i) } },
                    .wide = .wide,
                };
            }
            {
                const rac = page.getRowAndCell(i * 2 + 1, 0);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = 0 } },
                    .wide = .spacer_tail,
                };
            }
        }
    }

    // Resize to exactly two pairs per row: runs end on the row
    // boundary with no spacer heads needed.
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        for (0..4) |i| {
            const y = i / 2;
            const x = (i % 2) * 2;
            {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(0x4E00 + i)),
                    rac.cell.content.codepoint.data,
                );
                try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
            }
            {
                const rac = page.getRowAndCell(x + 1, y);
                try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
                try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
            }
        }

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expect(rac.row.wrap);
            try testing.expect(!rac.row.wrap_continuation);
        }
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expect(!rac.row.wrap);
            try testing.expect(rac.row.wrap_continuation);
        }
    }
}

test "PageList resize reflow less cols wide char bulk run odd cols spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 8, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        for (0..4) |i| {
            {
                const rac = page.getRowAndCell(i * 2, 0);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(0x4E00 + i) } },
                    .wide = .wide,
                };
            }
            {
                const rac = page.getRowAndCell(i * 2 + 1, 0);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = 0 } },
                    .wide = .spacer_tail,
                };
            }
        }
    }

    // Resize to an odd number of columns: the bulk run must stop a
    // pair short of the row boundary and the slow path inserts a
    // spacer head in the final column.
    try s.resize(.{ .cols = 5, .reflow = true });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        for (0..4) |i| {
            const y = i / 2;
            const x = (i % 2) * 2;
            {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(0x4E00 + i)),
                    rac.cell.content.codepoint.data,
                );
                try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
            }
            {
                const rac = page.getRowAndCell(x + 1, y);
                try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
                try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
            }
        }

        {
            const rac = page.getRowAndCell(4, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_head, rac.cell.wide);
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(4, 1);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(rac.row.wrap_continuation);
        }
    }
}

test "PageList resize reflow less cols wide char bulk run mixed narrow round trip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // The emoji-in-prose shape: single wide pairs separated by
    // narrow cells, which must all share a single bulk run.
    const Shape = struct { cp: u21, wide: pagepkg.Cell.Wide };
    const shape: []const Shape = &.{
        .{ .cp = 0x4E00, .wide = .wide },
        .{ .cp = 0, .wide = .spacer_tail },
        .{ .cp = 'x', .wide = .narrow },
        .{ .cp = 0x4E01, .wide = .wide },
        .{ .cp = 0, .wide = .spacer_tail },
        .{ .cp = 'y', .wide = .narrow },
        .{ .cp = 0x4E02, .wide = .wide },
        .{ .cp = 0, .wide = .spacer_tail },
        .{ .cp = 'z', .wide = .narrow },
    };

    var s = try init(alloc, .{ .cols = 9, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (shape, 0..) |c, x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = c.cp } },
                .wide = c.wide,
            };
        }
    }

    // Shrink: the run ends exactly on the row boundary after the
    // second narrow cell.
    try s.resize(.{ .cols = 6, .reflow = true });
    try testing.expectEqual(@as(usize, 6), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (shape[0..6], 0..) |c, x| {
            const rac = page.getRowAndCell(x, 0);
            try testing.expectEqual(c.cp, rac.cell.content.codepoint.data);
            try testing.expectEqual(c.wide, rac.cell.wide);
        }
        for (shape[6..], 0..) |c, x| {
            const rac = page.getRowAndCell(x, 1);
            try testing.expectEqual(c.cp, rac.cell.content.codepoint.data);
            try testing.expectEqual(c.wide, rac.cell.wide);
        }
        try testing.expect(page.getRowAndCell(0, 0).row.wrap);
        try testing.expect(page.getRowAndCell(0, 1).row.wrap_continuation);
    }

    // Grow back: the wrapped rows must rejoin into the original
    // single-row layout.
    try s.resize(.{ .cols = 9, .reflow = true });
    try testing.expectEqual(@as(usize, 9), s.cols);
    try testing.expectEqual(@as(usize, 1), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (shape, 0..) |c, x| {
            const rac = page.getRowAndCell(x, 0);
            try testing.expectEqual(c.cp, rac.cell.content.codepoint.data);
            try testing.expectEqual(c.wide, rac.cell.wide);
        }
        try testing.expect(!page.getRowAndCell(0, 0).row.wrap);
    }
}

test "PageList resize reflow less cols wide char bulk run styled" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 8, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // Create a style
        const style: stylepkg.Style = .{ .flags = .{ .bold = true } };
        const style_id = try page.styles.add(page.memory, style);

        // Styled pairs: the tail shares the wide cell's style, as
        // the print path writes them.
        for (0..4) |i| {
            {
                const rac = page.getRowAndCell(i * 2, 0);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(0x4E00 + i) } },
                    .wide = .wide,
                    .style_id = style_id,
                };
                page.styles.use(page.memory, style_id);
            }
            {
                const rac = page.getRowAndCell(i * 2 + 1, 0);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = 0 } },
                    .wide = .spacer_tail,
                    .style_id = style_id,
                };
                page.styles.use(page.memory, style_id);
            }
        }

        // We're over-counted by 1 because `add` implies `use`.
        page.styles.release(page.memory, style_id);
    }

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        for (0..2) |y| {
            for (0..4) |x| {
                const rac = page.getRowAndCell(x, y);
                const style_id = rac.cell.style_id;
                try testing.expect(style_id != 0);

                const style = page.styles.get(page.memory, style_id);
                try testing.expect(style.flags.bold);
                try testing.expect(rac.row.styled);
                try testing.expectEqual(
                    if (x % 2 == 0) pagepkg.Cell.Wide.wide else pagepkg.Cell.Wide.spacer_tail,
                    rac.cell.wide,
                );
            }
        }
    }
}

test "PageList resize reflow less cols wide char bulk run degenerate spacer tail style" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // A styled wide cell whose tail does NOT share its style.
        // This can't come from the print path, but the run scan must
        // reject the pair (slow path) rather than rewrite the tail
        // to the wide cell's style.
        const style: stylepkg.Style = .{ .flags = .{ .bold = true } };
        const style_id = try page.styles.add(page.memory, style);

        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0x4E00 } },
                .wide = .wide,
                .style_id = style_id,
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
        {
            const rac = page.getRowAndCell(2, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 3, .reflow = true });
    try testing.expectEqual(@as(usize, 3), s.cols);
    try testing.expectEqual(@as(usize, 1), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 0x4E00), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
            try testing.expect(rac.cell.style_id != 0);
            const style = page.styles.get(page.memory, rac.cell.style_id);
            try testing.expect(style.flags.bold);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
            try testing.expectEqual(stylepkg.default_id, rac.cell.style_id);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
    }
}

test "PageList resize reflow less cols to wrap a multi-codepoint grapheme with a spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // We want to make the screen look like this:
        //
        // 👨‍👨‍👦‍👦👨‍👨‍👦‍👦

        // First family emoji at (0, 0)
        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0x1F468 } }, // First codepoint of the grapheme
                .wide = .wide,
            };
            try page.setGraphemes(rac.row, rac.cell, &.{
                0x200D, 0x1F468,
                0x200D, 0x1F466,
                0x200D, 0x1F466,
            });
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
        // Second family emoji at (2, 0)
        {
            const rac = page.getRowAndCell(2, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0x1F468 } }, // First codepoint of the grapheme
                .wide = .wide,
            };
            try page.setGraphemes(rac.row, rac.cell, &.{
                0x200D, 0x1F468,
                0x200D, 0x1F466,
                0x200D, 0x1F466,
            });
        }
        {
            const rac = page.getRowAndCell(3, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 3, .reflow = true });
    try testing.expectEqual(@as(usize, 3), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 0x1F468), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);

            const cps = page.lookupGrapheme(rac.cell).?;
            try testing.expectEqual(@as(usize, 6), cps.len);
            try testing.expectEqual(@as(u21, 0x200D), cps[0]);
            try testing.expectEqual(@as(u21, 0x1F468), cps[1]);
            try testing.expectEqual(@as(u21, 0x200D), cps[2]);
            try testing.expectEqual(@as(u21, 0x1F466), cps[3]);
            try testing.expectEqual(@as(u21, 0x200D), cps[4]);
            try testing.expectEqual(@as(u21, 0x1F466), cps[5]);

            // Row should be wrapped
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_head, rac.cell.wide);
        }

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 0x1F468), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);

            const cps = page.lookupGrapheme(rac.cell).?;
            try testing.expectEqual(@as(usize, 6), cps.len);
            try testing.expectEqual(@as(u21, 0x200D), cps[0]);
            try testing.expectEqual(@as(u21, 0x1F468), cps[1]);
            try testing.expectEqual(@as(u21, 0x200D), cps[2]);
            try testing.expectEqual(@as(u21, 0x1F466), cps[3]);
            try testing.expectEqual(@as(u21, 0x200D), cps[4]);
            try testing.expectEqual(@as(u21, 0x1F466), cps[5]);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}

test "PageList resize reflow less cols copy kitty placeholder" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // Write unicode placeholders
        for (0..s.cols - 1) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.row.kitty_virtual_placeholder = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = kitty.graphics.unicode.placeholder } },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    while (it.next()) |offset| {
        for (0..s.cols - 1) |x| {
            var offset_copy = offset;
            offset_copy.x = @intCast(x);
            const rac = offset_copy.rowAndCell();

            const row = rac.row;
            try testing.expect(row.kitty_virtual_placeholder);
        }
    }
}

test "PageList resize reflow more cols clears kitty placeholder" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // Write unicode placeholders
        for (0..s.cols - 1) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.row.kitty_virtual_placeholder = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = kitty.graphics.unicode.placeholder } },
            };
        }
    }

    // Resize smaller then larger
    try s.resize(.{ .cols = 2, .reflow = true });
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const row = it.next().?;
        const rac = row.rowAndCell();
        try testing.expect(rac.row.kitty_virtual_placeholder);
    }
    {
        const row = it.next().?;
        const rac = row.rowAndCell();
        try testing.expect(!rac.row.kitty_virtual_placeholder);
    }
    try testing.expect(it.next() == null);
}

test "PageList resize reflow wrap moves kitty placeholder" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // Write unicode placeholders
        for (2..s.cols - 1) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.row.kitty_virtual_placeholder = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = kitty.graphics.unicode.placeholder } },
            };
        }
    }

    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), totalRows(&s));

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const row = it.next().?;
        const rac = row.rowAndCell();
        try testing.expect(!rac.row.kitty_virtual_placeholder);
    }
    {
        const row = it.next().?;
        const rac = row.rowAndCell();
        try testing.expect(rac.row.kitty_virtual_placeholder);
    }
    try testing.expect(it.next() == null);
}

test "PageList resize reflow grapheme map capacity exceeded" {
    // This test verifies that when reflowing content with many graphemes,
    // the grapheme map capacity is correctly increased when needed.
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 4, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Get the grapheme capacity from the page. We need more than this many
    // graphemes in a single destination page to trigger capacity increase
    // during reflow. Since each source page can only hold this many graphemes,
    // we create two source pages with graphemes that will merge into one
    // destination page.
    const grapheme_capacity = s.pages.first.?.page().graphemeCapacity();
    // Use slightly more than half the capacity per page, so combined they
    // exceed the capacity of a single destination page.
    const graphemes_per_page = grapheme_capacity / 2 + grapheme_capacity / 4;

    // Grow to the capacity of the first page and add more rows
    // so that we have two pages total.
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try growRows(&s, graphemes_per_page);
        try testing.expectEqual(@as(usize, 2), s.totalPages());

        // We now have two pages.
        try testing.expect(s.pages.first.? != s.pages.last.?);
        try testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }

    // Add graphemes to both pages. We add graphemes to rows at the END of the
    // first page, and graphemes to rows at the START of the second page.
    // When reflowing to 2 columns, these rows will wrap and stay together
    // on the same destination page, requiring capacity increase.

    // Add graphemes to the end of the first page (last rows)
    {
        const page = s.pages.first.?.page();
        const start_row = page.size.rows - graphemes_per_page;
        for (0..graphemes_per_page) |i| {
            const y = start_row + i;
            const rac = page.getRowAndCell(0, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
            };
            try page.appendGrapheme(rac.row, rac.cell, @as(u21, @intCast(0x0301)));
        }
    }

    // Add graphemes to the beginning of the second page
    {
        const page = s.pages.last.?.page();
        const count = @min(graphemes_per_page, page.size.rows);
        for (0..count) |y| {
            const rac = page.getRowAndCell(0, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'B' } },
            };
            try page.appendGrapheme(rac.row, rac.cell, @as(u21, @intCast(0x0302)));
        }
    }

    // Resize to fewer columns to trigger reflow.
    // The graphemes from both pages will be copied to destination pages.
    // They will all end up in a contiguous region of the destination.
    // If the bug exists (hyperlink_bytes increased instead of grapheme_bytes),
    // this will fail with GraphemeMapOutOfMemory when we exceed capacity.
    try s.resize(.{ .cols = 2, .reflow = true });

    // Verify the resize succeeded
    try testing.expectEqual(@as(usize, 2), s.cols);
}

test "PageList resize grow cols with unwrap fixes viewport pin" {
    // Regression test: after resize/reflow, the viewport pin can end up at a
    // position where pin.y + rows > total_rows, causing getBottomRight to panic.

    // The plan is to pin viewport in history, then grow columns to unwrap rows.
    // The unwrap reduces total_rows, but the tracked pin moves to a position
    // that no longer has enough rows below it for the viewport height.
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 10 });
    defer s.deinit();

    // Make sure we have some history, in this case we have 30 rows of history
    try growRows(&s, 30);
    try testing.expectEqual(@as(usize, 40), totalRows(&s));

    // Fill all rows with wrapped content (pairs that unwrap when cols increase)
    var it = s.pageIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |chunk| {
        const page = chunk.node.page();
        for (chunk.start..chunk.end) |y| {
            const rac = page.getRowAndCell(0, y);
            if (y % 2 == 0) {
                rac.row.wrap = true;
            } else {
                rac.row.wrap_continuation = true;
            }
            for (0..s.cols) |x| {
                page.getRowAndCell(x, y).cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = 'A' } },
                };
            }
        }
    }

    // Pin viewport at row 28 (in history, 2 rows before active area at row 30).
    // After unwrap: row 28 -> row 14, total_rows 40 -> 20, active starts at 10.
    // Pin at 14 needs rows 14-23, but only 0-19 exist -> overflow.
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = 28 } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expect(s.getBottomRight(.viewport) != null);

    // Resize with reflow: unwraps rows, reducing total_rows
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expect(totalRows(&s) < 40);

    // Used to panic here, so test that we can get the bottom right.
    const br_after = s.getBottomRight(.viewport);
    try testing.expect(br_after != null);
}

test "PageList resize (no reflow) more cols remaps pins in backfill path" {
    // Regression test: when resizeWithoutReflowGrowCols copies rows to a previous
    // page with spare capacity, tracked pins in those rows must be remapped.
    // Without the fix, pins become dangling pointers when the original page is destroyed.
    const testing = std.testing;
    const alloc = testing.allocator;

    const cols: size.CellCountInt = 5;
    const cap = try std_capacity.adjust(.{ .cols = cols });
    var s = try init(alloc, .{ .cols = cols, .rows = cap.rows });
    defer s.deinit();

    // Grow until we have two pages.
    while (s.pages.first == s.pages.last) {
        _ = try s.grow();
    }
    const first_page = s.pages.first.?;
    const second_page = s.pages.last.?;
    try testing.expect(first_page != second_page);

    // Trim a history row so the first page has spare capacity.
    // This triggers the backfill path in resizeWithoutReflowGrowCols.
    s.eraseHistory(.{ .history = .{ .y = 0 } });
    try testing.expect(first_page.rows() < first_page.capacity().rows);

    // Ensure the resize takes the slow path (new capacity > current capacity).
    const new_cols: size.CellCountInt = cols + 1;
    const adjusted = try second_page.capacity().adjust(.{ .cols = new_cols });
    try testing.expect(second_page.capacity().cols < adjusted.cols);

    // Track a pin in row 0 of the second page. This row will be copied
    // to the first page during backfill and the pin must be remapped.
    const tracked = try s.trackPin(.{ .node = second_page, .x = 0, .y = 0 });
    defer s.untrackPin(tracked);

    // Write a marker character to the tracked cell so we can verify
    // the pin points to the correct cell after resize.
    const marker: u21 = 'X';
    tracked.rowAndCell().cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = .{ .data = marker } },
    };

    try s.resize(.{ .cols = new_cols, .reflow = false });

    // Verify the pin points to a valid node still in the page list.
    var found = false;
    var it = s.pages.first;
    while (it) |node| : (it = node.next) {
        if (node == tracked.node) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
    try testing.expect(tracked.y < tracked.node.rows());

    // Verify the pin still points to the cell with our marker content.
    const cell = tracked.rowAndCell().cell;
    try testing.expectEqual(.codepoint, cell.content_tag);
    try testing.expectEqual(marker, cell.content.codepoint.data);
}

test "PageList increaseCapacity from zero-capacity dimensions" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();

    // Compact the only page. A plain page has no styled, grapheme,
    // or hyperlink content so the exact capacity is zero in every
    // managed dimension.
    var node = (try s.compact(s.pages.first.?)).?;
    try testing.expectEqual(0, node.capacity().styles);
    try testing.expectEqual(0, node.capacity().grapheme_bytes);
    try testing.expectEqual(0, node.capacity().string_bytes);
    try testing.expectEqual(0, node.capacity().hyperlink_bytes);

    // Increasing each dimension from zero must actually grow it.
    // Regression: 0 * 2 == 0 used to "succeed" without growing,
    // which turned caller retry loops into infinite loops.
    node = try s.increaseCapacity(node, .styles);
    try testing.expect(node.capacity().styles > 0);
    node = try s.increaseCapacity(node, .grapheme_bytes);
    try testing.expect(node.capacity().grapheme_bytes > 0);
    node = try s.increaseCapacity(node, .string_bytes);
    try testing.expect(node.capacity().string_bytes > 0);
    node = try s.increaseCapacity(node, .hyperlink_bytes);
    try testing.expect(node.capacity().hyperlink_bytes > 0);

    // Increasing a non-zero dimension still doubles.
    const styles = node.capacity().styles;
    node = try s.increaseCapacity(node, .styles);
    try testing.expectEqual(styles * 2, node.capacity().styles);
}

test "PageList compact after increaseCapacity" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();

    var node = s.pages.first.?;

    // Grow the page capacity. The content is unchanged, so compaction
    // should always shrink it back down to an exact-size heap page.
    node = try s.increaseCapacity(node, .grapheme_bytes);
    const grown_len = node.page().memory.len;

    const new_node = (try s.compact(node)).?;
    try testing.expectEqual(.heap, new_node.owned);
    try testing.expect(new_node.page().memory.len < grown_len);
    try testing.expect(new_node.page().memory.len < std_size);
}

test "PageList resize trimmed rows have default state" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 5 });
    defer s.deinit();

    // A trailing blank row has no text, so shrinking rows trims it,
    // but it can still carry metadata (e.g. a blank prompt
    // continuation line) and background-colored cells. Trimming
    // retires the storage into unused capacity that grow()
    // re-exposes without clearing.
    {
        const rac = s.getCell(.{ .active = .{ .y = 4 } }).?;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt_continuation;
        rac.cell.* = .{
            .content_tag = .bg_color_palette,
            .content = .{ .color_palette = .{ .data = 42 } },
        };
    }

    try s.resize(.{ .rows = 4, .reflow = false });
    try s.resize(.{ .rows = 5, .reflow = false });

    {
        const rac = s.getCell(.{ .active = .{ .y = 4 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
        try testing.expect(rac.cell.isZero());
    }
}
