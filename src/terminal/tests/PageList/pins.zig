//! PageList pins regression tests.
const nodeIsCompressed = support.nodeIsCompressed;
const support = @import("support.zig");
const PageList = support.PageList;
const std = support.std;
const point = support.point;
const size = support.size;
const page_preheat = support.page_preheat;
const List = support.List;
const Node = support.Node;
const std_capacity = support.std_capacity;
const std_size = support.std_size;
const Viewport = support.Viewport;
const init = support.init;
const Clone = support.Clone;
const Scrollbar = support.Scrollbar;
const CompressionIterator = support.CompressionIterator;
const totalRows = support.totalRows;
const growRows = support.growRows;
const Pin = support.Pin;
const Cell = support.Cell;
const mixedWidthPinListForTest = support.mixedWidthPinListForTest;
const growColdPagesForTest = support.growColdPagesForTest;

test "PageList Pin row movement clamps across mixed-width pages" {
    const testing = std.testing;

    var s = try mixedWidthPinListForTest(testing.allocator);
    defer s.deinit();

    const first = s.pages.first.?;
    const second = first.next.?;
    const third = second.next.?;

    try testing.expect((Pin{ .node = third, .x = 2 }).eql(
        (Pin{ .node = second, .x = 3 }).down(1).?,
    ));
    try testing.expect((Pin{ .node = first, .x = 1 }).eql(
        (Pin{ .node = second, .x = 3 }).up(1).?,
    ));

    switch ((Pin{ .node = second, .x = 3 }).downOverflow(10)) {
        .offset => try testing.expect(false),
        .overflow => |overflow| try testing.expect(
            (Pin{ .node = third, .x = 2 }).eql(overflow.end),
        ),
    }
    switch ((Pin{ .node = second, .x = 3 }).upOverflow(10)) {
        .offset => try testing.expect(false),
        .overflow => |overflow| try testing.expect(
            (Pin{ .node = first, .x = 1 }).eql(overflow.end),
        ),
    }
}

test "PageList Pin wrapping crosses mixed-width pages" {
    const testing = std.testing;

    var s = try mixedWidthPinListForTest(testing.allocator);
    defer s.deinit();

    const first = s.pages.first.?;
    const second = first.next.?;
    const third = second.next.?;

    try testing.expect((Pin{ .node = third, .x = 2 }).eql(
        (Pin{ .node = first, .x = 1 }).rightWrap(7).?,
    ));
    try testing.expect((Pin{ .node = second, .x = 0 }).eql(
        (Pin{ .node = third, .x = 2 }).leftWrap(6).?,
    ));
    try testing.expect((Pin{ .node = first }).leftWrap(1) == null);
    try testing.expect((Pin{ .node = third, .x = 2 }).rightWrap(1) == null);
}

test "PageList Pin rejects columns beyond mixed-width page bounds" {
    const testing = std.testing;

    var s = try mixedWidthPinListForTest(testing.allocator);
    defer s.deinit();

    try testing.expect(s.pin(.{ .screen = .{ .x = 1, .y = 0 } }) != null);
    try testing.expect(s.pin(.{ .screen = .{ .x = 2, .y = 0 } }) == null);
    try testing.expect(s.pin(.{ .screen = .{ .x = 3, .y = 1 } }) != null);
    try testing.expect(s.pin(.{ .screen = .{ .x = 3, .y = 2 } }) == null);
}

test "PageList Pin rightWrap exact row multiple" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 10, .rows = 3 });
    defer s.deinit();

    const start = s.pin(.{ .active = .{ .x = 5, .y = 0 } }).?;
    const wrapped = start.rightWrap(14).?;
    _ = wrapped.rowAndCell();

    try testing.expectEqual(
        point.Point{ .active = .{ .x = 9, .y = 1 } },
        s.pointFromPin(.active, wrapped),
    );
}

test "PageList Pin leftWrap exact row multiple" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 10, .rows = 3 });
    defer s.deinit();

    const start = s.pin(.{ .active = .{ .x = 5, .y = 2 } }).?;
    const wrapped = start.leftWrap(15).?;
    _ = wrapped.rowAndCell();

    try testing.expectEqual(
        point.Point{ .active = .{ .x = 0, .y = 1 } },
        s.pointFromPin(.active, wrapped),
    );
}

test "PageList Pin rightWrap maximum distance" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 1, .rows = 3 });
    defer s.deinit();

    const start = s.pin(.{ .active = .{ .y = 0 } }).?;
    try testing.expectEqual(null, start.rightWrap(std.math.maxInt(usize)));
}

test "PageList Pin leftWrap maximum distance" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 1, .rows = 3 });
    defer s.deinit();

    const start = s.pin(.{ .active = .{ .y = 2 } }).?;
    try testing.expectEqual(null, start.leftWrap(std.math.maxInt(usize)));
}

test "PageList full and incremental compression skip a spanning viewport" {
    const testing = std.testing;

    var full = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer full.deinit();
    try growColdPagesForTest(&full, 3);

    var incremental = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer incremental.deinit();
    try growColdPagesForTest(&incremental, 3);

    // Start near the end of the first page so the viewport intersects both
    // the first and second historical page mappings.
    const first = full.pages.first.?;
    const overlap_rows: usize = full.rows / 2;
    const viewport_row: usize = first.rows() - overlap_rows;
    full.scroll(.{ .row = viewport_row });
    incremental.scroll(.{ .row = viewport_row });
    try testing.expect(
        full.getTopLeft(.viewport).node !=
            full.getBottomRight(.viewport).?.node,
    );
    const second = first.next.?;
    try testing.expectEqual(first, full.getTopLeft(.viewport).node);
    try testing.expectEqual(second, full.getBottomRight(.viewport).?.node);

    _ = full.compress(.full);
    _ = incremental.compress(.drain);
    try testing.expectEqual(full.memoryStats(), incremental.memoryStats());
    try testing.expect(!nodeIsCompressed(first));
    try testing.expect(!nodeIsCompressed(second));

    const full_active = full.getTopLeft(.active).node;
    const incremental_active = incremental.getTopLeft(.active).node;
    var full_node = full.pages.first.?;
    var incremental_node = incremental.pages.first.?;
    while (full_node != full_active) {
        try testing.expectEqual(
            nodeIsCompressed(full_node),
            nodeIsCompressed(incremental_node),
        );

        full_node = full_node.next.?;
        incremental_node = incremental_node.next.?;
    }
    try testing.expectEqual(incremental_active, incremental_node);

    var eligible: CompressionIterator = PageList.TestAccess.compressionIterator(&full);
    var compressed_pages: usize = 0;
    while (PageList.TestAccess.nextCompressionPage(&eligible)) |node| {
        compressed_pages += 1;
        try testing.expect(nodeIsCompressed(node));
    }
    try testing.expect(compressed_pages > 0);
}

test "PageList pointFromPin active no history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    {
        try testing.expectEqual(point.Point{
            .active = .{
                .y = 0,
                .x = 0,
            },
        }, s.pointFromPin(.active, .{
            .node = s.pages.first.?,
            .y = 0,
            .x = 0,
        }).?);
    }
    {
        try testing.expectEqual(point.Point{
            .active = .{
                .y = 2,
                .x = 4,
            },
        }, s.pointFromPin(.active, .{
            .node = s.pages.first.?,
            .y = 2,
            .x = 4,
        }).?);
    }
}

test "PageList pointFromPin active with history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 30);

    {
        try testing.expectEqual(point.Point{
            .active = .{
                .y = 0,
                .x = 2,
            },
        }, s.pointFromPin(.active, .{
            .node = s.pages.first.?,
            .y = 30,
            .x = 2,
        }).?);
    }

    // In history, invalid
    {
        try testing.expect(s.pointFromPin(.active, .{
            .node = s.pages.first.?,
            .y = 21,
            .x = 2,
        }) == null);
    }
}

test "PageList pointFromPin active from prior page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    // Grow so we take up at least 5 pages.
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);

    {
        try testing.expectEqual(point.Point{
            .active = .{
                .y = 0,
                .x = 2,
            },
        }, s.pointFromPin(.active, .{
            .node = s.pages.last.?,
            .y = 0,
            .x = 2,
        }).?);
    }

    // Prior page
    {
        try testing.expect(s.pointFromPin(.active, .{
            .node = s.pages.first.?,
            .y = 0,
            .x = 0,
        }) == null);
    }
}

test "PageList pointFromPin traverse pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow so we take up at least 2 pages.
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 2) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);

    {
        const pages = s.totalPages();
        const page_cap = page.capacity.rows;
        const expected_y = page_cap * (pages - 2) + 5;

        try testing.expectEqual(point.Point{
            .screen = .{
                .y = @intCast(expected_y),
                .x = 2,
            },
        }, s.pointFromPin(.screen, .{
            .node = s.pages.last.?.prev.?,
            .y = 5,
            .x = 2,
        }).?);
    }

    // Prior page
    {
        try testing.expect(s.pointFromPin(.active, .{
            .node = s.pages.first.?,
            .y = 0,
            .x = 0,
        }) == null);
    }
}

test "PageList pointFromPin rejects overflowing screen coordinate" {
    const testing = std.testing;

    // Use maximum-height metadata-only pages to model a valid scrollback just
    // beyond the u32 coordinate range without allocating their backing cells.
    const page_count = 65_539;
    const rows_per_page = std.math.maxInt(size.CellCountInt);
    const nodes = try testing.allocator.alloc(Node, page_count);
    defer testing.allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = .{
            .prev = if (i > 0) &nodes[i - 1] else null,
            .next = if (i + 1 < nodes.len) &nodes[i + 1] else null,
            .data = .{ .resident = undefined },
            .serial = @intCast(i),
            .owned = .heap,
        };
        node.data.resident.size = .{
            .cols = 1,
            .rows = rows_per_page,
        };
    }

    var s: PageList = undefined;
    s.pages = .{
        .first = &nodes[0],
        .last = &nodes[nodes.len - 1],
    };

    try testing.expect(s.pointFromPin(.screen, .{
        .node = &nodes[nodes.len - 1],
        .y = 0,
        .x = 0,
    }) == null);
}

test "PageList scrollbar with max_size 0 after grow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();

    // Grow some rows (simulates normal terminal output)
    try growRows(&s, 10);

    const sb = s.scrollbar();

    // With no scrollback (max_size = 0), total should equal rows
    try testing.expectEqual(s.rows, sb.total);

    // With no scrollback, offset should be 0 (nowhere to scroll back to)
    try testing.expectEqual(@as(usize, 0), sb.offset);
}

test "PageList scroll with max_size 0 no history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();

    try growRows(&s, 10);

    // Remember initial viewport position
    const pt_before = s.getCell(.{ .viewport = .{} }).?.screenPoint();

    // Try to scroll backwards into "history" - should be no-op
    s.scroll(.{ .delta_row = -5 });
    try testing.expect(s.viewport == .active);

    // Scroll to top - should also be no-op with no scrollback
    s.scroll(.{ .top = {} });
    const pt_after = s.getCell(.{ .viewport = .{} }).?.screenPoint();
    try testing.expectEqual(pt_before, pt_after);
}

test "PageList scroll top" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 10);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    s.scroll(.{ .top = {} });

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());

    try growRows(&s, 10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());

    s.scroll(.{ .active = {} });
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 20,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll delta row back" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 10);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    s.scroll(.{ .delta_row = -1 });

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = s.total_rows - s.rows - 1,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 9,
        } }, pt);
    }

    try growRows(&s, 10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 9,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = s.total_rows - s.rows - 11,
        .len = s.rows,
    }, s.scrollbar());

    s.scroll(.{ .delta_row = -1 });

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = s.total_rows - s.rows - 12,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll delta row back overflow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 10);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    s.scroll(.{ .delta_row = -100 });

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());

    try growRows(&s, 10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll minimum row delta" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 10, .rows = 3 });
    defer s.deinit();

    // Create one row of history so scrolling all the way back has an
    // observable result.
    try growRows(&s, 1);
    s.scroll(.{ .delta_row = std.math.minInt(isize) });

    try testing.expectEqual(Viewport.top, s.viewport);
}

test "PageList scroll delta row forward" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 10);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    s.scroll(.{ .top = {} });
    s.scroll(.{ .delta_row = 2 });

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = 2,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }

    try growRows(&s, 10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = 2,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll delta row forward into active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    s.scroll(.{ .delta_row = 2 });

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll delta row back without space preserves active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    s.scroll(.{ .delta_row = -1 });

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expect(s.viewport == .active);

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to pin" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 10);

    s.scroll(.{ .pin = s.pin(.{ .screen = .{
        .y = 4,
        .x = 2,
    } }).? });

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = 4,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 4,
        } }, pt);
    }

    s.scroll(.{ .pin = s.pin(.{ .screen = .{
        .y = 5,
        .x = 2,
    } }).? });

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = 5,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }
}

test "PageList scroll to pin in active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 10);

    s.scroll(.{ .pin = s.pin(.{ .screen = .{
        .y = 30,
        .x = 2,
    } }).? });

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
}

test "PageList scroll to pin at top" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 10);

    s.scroll(.{ .pin = s.pin(.{ .screen = .{
        .y = 0,
        .x = 2,
    } }).? });

    try testing.expect(s.viewport == .top);

    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}

test "PageList scroll to row 0" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 10);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    s.scroll(.{ .row = 0 });
    try testing.expect(s.viewport == .top);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());

    try growRows(&s, 10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row in scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 20);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 20,
        } }, pt);
    }

    s.scroll(.{ .row = 5 });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 5,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }

    try growRows(&s, 10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 5,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row in middle" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 50);

    const total = s.total_rows;
    const midpoint = total / 2;
    s.scroll(.{ .row = midpoint });

    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = midpoint,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = @as(size.CellCountInt, @intCast(midpoint)),
        } }, pt);
    }

    try growRows(&s, 10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = @as(size.CellCountInt, @intCast(midpoint)),
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = midpoint,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row at active boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 20);

    const active_start = s.total_rows - s.rows;

    s.scroll(.{ .row = active_start });

    try testing.expect(s.viewport == .active);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = @as(size.CellCountInt, @intCast(active_start)),
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());

    try growRows(&s, 10);

    try testing.expect(s.viewport == .active);

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row beyond active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 10);

    s.scroll(.{ .row = 1000 });

    try testing.expect(s.viewport == .active);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row without scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    s.scroll(.{ .row = 5 });

    try testing.expect(s.viewport == .active);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row then delta" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 30);

    s.scroll(.{ .row = 10 });

    try testing.expect(s.viewport == .pin);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 10,
        .len = s.rows,
    }, s.scrollbar());

    s.scroll(.{ .delta_row = 5 });

    try testing.expect(s.viewport == .pin);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 15,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 15,
        .len = s.rows,
    }, s.scrollbar());

    s.scroll(.{ .delta_row = -3 });

    try testing.expect(s.viewport == .pin);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 12,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 12,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row with cache fast path down" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 50);

    s.scroll(.{ .row = 10 });

    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 10,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    // Verify cache is populated
    try testing.expect(s.viewport_pin_row_offset != null);
    try testing.expectEqual(@as(usize, 10), s.viewport_pin_row_offset.?);

    // Now scroll to a different row - this should use the fast path
    s.scroll(.{ .row = 20 });

    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 20,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 20,
        } }, pt);
    }

    try growRows(&s, 10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 20,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 20,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row with cache fast path up" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growRows(&s, 50);

    s.scroll(.{ .row = 30 });

    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 30,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 30,
        } }, pt);
    }

    // Verify cache is populated
    try testing.expect(s.viewport_pin_row_offset != null);
    try testing.expectEqual(@as(usize, 30), s.viewport_pin_row_offset.?);

    // Now scroll up to a different row - this should use the fast path
    s.scroll(.{ .row = 15 });

    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 15,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 15,
        } }, pt);
    }

    try growRows(&s, 10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 15,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 15,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll clear" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    {
        const cell = s.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        cell.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }
    {
        const cell = s.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        cell.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }

    try s.scrollClear();

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }
}

test "PageList Cell screenPoint supports long scrollback" {
    const testing = std.testing;

    // A modest number of full-size page nodes is enough to exceed the u16
    // row range without allocating any page backing memory. screenPoint only
    // reads the linked metadata while calculating the absolute coordinate.
    const page_count = 307;
    const rows_per_page = std_capacity.rows;
    const nodes = try testing.allocator.alloc(Node, page_count);
    defer testing.allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = .{
            .prev = if (i > 0) &nodes[i - 1] else null,
            .next = if (i + 1 < nodes.len) &nodes[i + 1] else null,
            .data = .{ .resident = undefined },
            .serial = @intCast(i),
            .owned = .heap,
        };
        node.data.resident.size = .{
            .cols = 1,
            .rows = rows_per_page,
        };
    }

    const expected_y: u32 = (page_count - 1) * @as(u32, rows_per_page);
    try testing.expect(expected_y > std.math.maxInt(size.CellCountInt));

    const cell: Cell = .{
        .node = &nodes[nodes.len - 1],
        .row = undefined,
        .cell = undefined,
        .row_idx = 0,
        .col_idx = 0,
    };
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = expected_y,
    } }, cell.screenPoint());
}

test "PageList grow prune scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Use std_size to limit scrollback so pruning is triggered.
    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = std_size });
    defer s.deinit();

    // Grow to capacity
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }

    // Grow and allocate one more page. Then fill that page up.
    const page2_node = (try s.grow()).?;
    const page2 = page2_node.page();
    for (0..page2.capacity.rows - page2.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }

    // Get our page size
    const old_page_size = s.page_size;

    // Create a tracked pin in the first page
    const p = try s.trackPin(s.pin(.{ .screen = .{} }).?);
    defer s.untrackPin(p);
    try testing.expect(p.node == s.pages.first.?);

    // Scroll back to create a pinned viewport (not active)
    const pin_y = page1.capacity.rows / 2;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);

    // Get the scrollbar state to populate the cache
    const scrollbar_before = s.scrollbar();
    try testing.expectEqual(pin_y, scrollbar_before.offset);

    // Next should create a new page, but it should reuse our first
    // page since we're at max size.
    const new = (try s.grow()).?;
    try testing.expect(s.pages.last.? == new);
    try testing.expectEqual(s.page_size, old_page_size);

    // Our first should now be page2 and our last should be page1
    try testing.expectEqual(page2_node, s.pages.first.?);
    try testing.expectEqual(page1_node, s.pages.last.?);

    // Our tracked pin should point to the top-left of the first page
    try testing.expect(p.node == s.pages.first.?);
    try testing.expect(p.x == 0);
    try testing.expect(p.y == 0);
    try testing.expect(p.garbage);

    // Verify the viewport offset cache was invalidated. After pruning,
    // the offset should have changed because we removed rows from
    // the beginning.
    {
        const scrollbar_after = s.scrollbar();
        const rows_pruned = page1.capacity.rows;
        const expected_offset = if (pin_y >= rows_pruned)
            pin_y - rows_pruned
        else
            0;
        try testing.expectEqual(expected_offset, scrollbar_after.offset);
    }
}

test "PageList grow prune scrollback with viewport pin not in pruned page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Use std_size to limit scrollback so pruning is triggered.
    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = std_size });
    defer s.deinit();

    // Grow to capacity of first page
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }

    // Grow and allocate second page, then fill it up
    const page2_node = (try s.grow()).?;
    const page2 = page2_node.page();
    for (0..page2.capacity.rows - page2.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }

    // Get our page size
    const old_page_size = s.page_size;

    // Scroll back to create a pinned viewport in page2 (NOT page1)
    // This is the key difference from the previous test - the viewport
    // pin is NOT in the page that will be pruned.
    const pin_y = page1.capacity.rows + 5;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expect(s.viewport_pin.node == page2_node);

    // Get the scrollbar state to populate the cache
    const scrollbar_before = s.scrollbar();
    try testing.expectEqual(pin_y, scrollbar_before.offset);

    // Next grow will trigger pruning of the first page.
    // The viewport_pin.node is page2, not page1, so it won't be moved
    // by the pin update loop, but the cached offset still needs to be
    // invalidated because rows were removed from the beginning.
    const new = (try s.grow()).?;
    try testing.expect(s.pages.last.? == new);
    try testing.expectEqual(s.page_size, old_page_size);

    // Our first should now be page2 (page1 was pruned)
    try testing.expectEqual(page2_node, s.pages.first.?);

    // The viewport pin should still be on page2, unchanged
    try testing.expect(s.viewport_pin.node == page2_node);

    // Verify the viewport offset cache was invalidated/updated.
    // After pruning, the offset should have decreased by the number
    // of rows that were pruned.
    const scrollbar_after = s.scrollbar();
    const rows_pruned = page1.capacity.rows;
    const expected_offset = pin_y - rows_pruned;
    try testing.expectEqual(expected_offset, scrollbar_after.offset);
}

test "PageList eraseRows invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow so we take up several pages worth of history
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }

    // Scroll back to create a pinned viewport somewhere in the middle
    // of the scrollback
    const pin_y = page.capacity.rows;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Erase some history rows BEFORE the viewport pin.
    // This removes rows from before our pin, which changes its absolute
    // offset from the top, but the cache is not invalidated.
    const rows_to_erase = page.capacity.rows / 2;
    s.eraseHistory(.{ .history = .{ .y = rows_to_erase - 1 } });

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - rows_to_erase,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList eraseRow invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow so we take up several pages worth of history
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }

    // Scroll back to create a pinned viewport somewhere in the middle
    // of the scrollback
    const pin_y = page.capacity.rows;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Erase a single row from the history BEFORE the viewport pin.
    // This removes one row from before our pin, which changes its absolute
    // offset from the top by 1, but the cache is not invalidated.
    try s.eraseRow(.{ .history = .{ .y = 0 } });

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList eraseRowBounded invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow so we take up several pages worth of history
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }

    // Scroll back to create a pinned viewport somewhere in the middle
    // of the scrollback
    const pin_y: u16 = 4;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Erase a row from the history BEFORE the viewport pin with a bounded
    // shift. This removes one row from before our pin, which changes its
    // absolute offset from the top by 1, but the cache is not invalidated.
    try s.eraseRowBounded(.{ .history = .{ .y = 0 } }, 10);

    // Verify the scrollbar reflects the change (offset decreased by 1)
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList eraseRowBounded multi-page invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow so we take up several pages worth of history
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }

    // Scroll back to create a pinned viewport somewhere in the middle
    // of the scrollback, after the first page
    const pin_y = page.capacity.rows + 1;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Erase a row from the beginning of history with a limit that spans
    // across multiple pages. This ensures we hit the code path where
    // eraseRowBounded finds the limit boundary in a subsequent page.
    const limit = page.capacity.rows + 10;
    try s.eraseRowBounded(.{ .history = .{ .y = 0 } }, limit);

    // Verify the scrollbar reflects the change (offset decreased by 1)
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList eraseRowBounded full page shift invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow so we take up several pages worth of history
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 4) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }

    // Scroll back to create a pinned viewport somewhere well beyond
    // the first two pages
    const pin_y = 5;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Erase a row from the beginning of history with a limit that is
    // larger than multiple full pages. This ensures we hit the code path
    // where eraseRowBounded continues looping through entire pages,
    // rotating all rows in each page until it reaches the limit or
    // runs out of pages.
    const limit = page.capacity.rows * 2 + 10;
    try s.eraseRowBounded(.{ .history = .{ .y = 0 } }, limit);

    // Verify the scrollbar reflects the change (offset decreased by 1)
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList eraseRowBounded exhausts pages invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow so we take up several pages worth of history
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }

    // Our total rows should include history
    const total_rows_before = totalRows(&s);
    try testing.expect(total_rows_before > s.rows);

    // Scroll back to create a pinned viewport somewhere in the history,
    // well after the erase will complete
    const pin_y = page.capacity.rows * 2 + 10;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Erase a row from the beginning of history with a limit that is
    // LARGER than all remaining pages combined. This ensures we exhaust
    // all pages in the while loop and reach the cleanup code after the loop.
    const limit = total_rows_before * 2;
    try s.eraseRowBounded(.{ .history = .{ .y = 0 } }, limit);

    // Verify the scrollbar reflects the change (offset decreased by 1)
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList erase row with tracked pin resets to top-left" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow so we take up at least 5 pages.
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);

    // Our total rows should be large
    try testing.expect(s.total_rows > s.rows);

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .history = .{} }).?);
    defer s.untrackPin(p);

    // Erase the entire history, we should be back to just our active set.
    s.eraseHistory(null);
    try testing.expectEqual(s.rows, s.total_rows);

    // Our pin should move to the first page
    try testing.expectEqual(s.pages.first.?, p.node);
    try testing.expectEqual(@as(usize, 0), p.y);
    try testing.expectEqual(@as(usize, 0), p.x);
}

test "PageList erase row with tracked pin shifts" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .y = 4, .x = 2 } }).?);
    defer s.untrackPin(p);

    // Erase only a few rows in our active
    s.eraseActive(3);
    try testing.expectEqual(s.rows, s.total_rows);

    // Our pin should move to the first page
    try testing.expectEqual(s.pages.first.?, p.node);
    try testing.expectEqual(@as(usize, 0), p.y);
    try testing.expectEqual(@as(usize, 2), p.x);
}

test "PageList erase row with tracked pin is erased" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .y = 2, .x = 2 } }).?);
    defer s.untrackPin(p);

    // Erase the entire history, we should be back to just our active set.
    s.eraseActive(3);
    try testing.expectEqual(s.rows, s.total_rows);

    // Our pin should move to the first page
    try testing.expectEqual(s.pages.first.?, p.node);
    try testing.expectEqual(@as(usize, 0), p.y);
    try testing.expectEqual(@as(usize, 0), p.x);
}

test "PageList erase resets viewport to active if moves within active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow so we take up at least 5 pages.
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);

    // Move our viewport to the top
    s.scroll(.{ .delta_row = -@as(isize, @intCast(s.total_rows)) });
    try testing.expect(s.viewport == .top);

    // Erase the entire history, we should be back to just our active set.
    s.eraseHistory(null);
    try testing.expect(s.viewport == .active);
}

test "PageList erase resets viewport if inside erased page but not active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow so we take up at least 5 pages.
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);

    // Move our viewport to the top
    s.scroll(.{ .delta_row = -@as(isize, @intCast(s.total_rows)) });
    try testing.expect(s.viewport == .top);

    // Erase the entire history, we should be back to just our active set.
    s.eraseHistory(.{ .history = .{ .y = 2 } });
    try testing.expect(s.viewport == .top);
}

test "PageList erase resets viewport to active if top is inside active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow so we take up at least 5 pages.
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);

    // Move our viewport to the top
    s.scroll(.{ .top = {} });

    // Erase the entire history, we should be back to just our active set.
    s.eraseHistory(null);
    try testing.expect(s.viewport == .active);
}

test "PageList eraseRowBounded with pin at top" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 10 });
    defer s.deinit();

    // Pins
    const p_top = try s.trackPin(s.pin(.{ .active = .{ .y = 0, .x = 5 } }).?);
    defer s.untrackPin(p_top);

    // Erase only a few rows in our active
    try s.eraseRowBounded(.{ .active = .{ .y = 0 } }, 3);
    try testing.expectEqual(s.rows, totalRows(&s));

    // The erased rows should be dirty
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    try testing.expectEqual(s.pages.first.?, p_top.node);
    try testing.expectEqual(@as(usize, 0), p_top.y);
    try testing.expectEqual(@as(usize, 0), p_top.x);
}

test "PageList clone remap tracked pin" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));

    // Put a tracked pin in the screen
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 6 } }).?);
    defer s.untrackPin(p);

    var pin_remap = Clone.TrackedPinsRemap.init(alloc);
    defer pin_remap.deinit();
    var s2 = try s.clone(alloc, .{
        .top = .{ .active = .{ .y = 5 } },
        .tracked_pins = &pin_remap,
    });
    defer s2.deinit();

    // We should be able to find our tracked pin
    const p2 = pin_remap.get(p).?;
    try testing.expectEqual(
        point.Point{ .active = .{ .x = 0, .y = 1 } },
        s2.pointFromPin(.active, p2.*).?,
    );
}

test "PageList clone remap tracked pin not in cloned area" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));

    // Put a tracked pin in the screen
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 3 } }).?);
    defer s.untrackPin(p);

    var pin_remap = Clone.TrackedPinsRemap.init(alloc);
    defer pin_remap.deinit();
    var s2 = try s.clone(alloc, .{
        .top = .{ .active = .{ .y = 5 } },
        .tracked_pins = &pin_remap,
    });
    defer s2.deinit();

    // We should be able to find our tracked pin
    try testing.expect(pin_remap.get(p) == null);
}

test "PageList reset invalidates stale untracked refs even if node memory is reused" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    var stale_nodes: [page_preheat * 4]*List.Node = undefined;
    var stale_serials: [stale_nodes.len]u64 = undefined;
    var stale_len: usize = 0;
    var reused: ?struct { *List.Node, u64 } = null;

    while (stale_len < stale_nodes.len and reused == null) {
        const old_node = s.pages.first.?;
        const old_serial = old_node.serial;
        try testing.expect(old_serial >= s.page_serial_epoch);
        try testing.expect(old_serial < s.page_serial);
        stale_nodes[stale_len] = old_node;
        stale_serials[stale_len] = old_serial;
        stale_len += 1;

        s.reset();

        const new_node = s.pages.first.?;
        for (stale_nodes[0..stale_len], stale_serials[0..stale_len]) |node, serial| {
            if (node == new_node) {
                reused = .{ node, serial };
                break;
            }
        }
    }

    try testing.expect(reused != null);
    const old_node, const old_serial = reused.?;
    const new_node = s.pages.first.?;
    const new_serial = new_node.serial;

    // Reset advances the epoch before rebuilding from the node pool. Reject
    // the stale generation before inspecting its pointer, even when that exact
    // address now belongs to a new live generation.
    try testing.expectEqual(old_node, new_node);
    try testing.expect(old_serial < s.page_serial_epoch);
    try testing.expect(!s.nodeIsValid(old_node, old_serial));
    try testing.expect(s.nodeIsValid(new_node, new_serial));
    try testing.expect(new_serial >= s.page_serial_epoch);
    try testing.expect(new_serial < s.page_serial);
}

test "PageList reset moves tracked pins and marks them as garbage" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Create a tracked pin into the active area
    const p = try s.trackPin(s.pin(.{ .active = .{
        .x = 42,
        .y = 12,
    } }).?);
    defer s.untrackPin(p);

    s.reset();

    // Our added pin should now be garbage
    try testing.expect(p.garbage);

    // Viewport pin should not be garbage because it makes sense.
    try testing.expect(!s.viewport_pin.garbage);
}

test "PageList split moves tracked pins" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    // Track a pin at row 7
    const tracked = try s.trackPin(.{ .node = s.pages.first.?, .y = 7, .x = 3 });
    defer s.untrackPin(tracked);

    // Split at row 5
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);

    // The tracked pin should now be in the second page
    try testing.expect(tracked.node == s.pages.first.?.next.?);
    // y should be adjusted: was 7, split at 5, so new y = 7 - 5 = 2
    try testing.expectEqual(@as(usize, 2), tracked.y);
    // x should remain unchanged
    try testing.expectEqual(@as(usize, 3), tracked.x);
}

test "PageList split tracked pin before split point unchanged" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    const original_node = s.pages.first.?;

    // Track a pin at row 2 (before the split point)
    const tracked = try s.trackPin(.{ .node = original_node, .y = 2, .x = 5 });
    defer s.untrackPin(tracked);

    // Split at row 5
    const split_pin: Pin = .{ .node = original_node, .y = 5, .x = 0 };
    try s.split(split_pin);

    // The tracked pin should remain in the original page
    try testing.expect(tracked.node == s.pages.first.?);
    // y and x should be unchanged
    try testing.expectEqual(@as(usize, 2), tracked.y);
    try testing.expectEqual(@as(usize, 5), tracked.x);
}

test "PageList split tracked pin at split point moves to new page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    const original_node = s.pages.first.?;

    // Track a pin at the exact split point (row 5)
    const tracked = try s.trackPin(.{ .node = original_node, .y = 5, .x = 4 });
    defer s.untrackPin(tracked);

    // Split at row 5
    const split_pin: Pin = .{ .node = original_node, .y = 5, .x = 0 };
    try s.split(split_pin);

    // The tracked pin should be in the new page
    try testing.expect(tracked.node == s.pages.first.?.next.?);
    // y should be 0 since it was at the split point: 5 - 5 = 0
    try testing.expectEqual(@as(usize, 0), tracked.y);
    // x should remain unchanged
    try testing.expectEqual(@as(usize, 4), tracked.x);
}

test "PageList split multiple tracked pins across regions" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    const original_node = s.pages.first.?;

    // Track multiple pins in different regions
    const pin_before = try s.trackPin(.{ .node = original_node, .y = 1, .x = 0 });
    defer s.untrackPin(pin_before);
    const pin_at_split = try s.trackPin(.{ .node = original_node, .y = 5, .x = 2 });
    defer s.untrackPin(pin_at_split);
    const pin_after1 = try s.trackPin(.{ .node = original_node, .y = 7, .x = 3 });
    defer s.untrackPin(pin_after1);
    const pin_after2 = try s.trackPin(.{ .node = original_node, .y = 9, .x = 8 });
    defer s.untrackPin(pin_after2);

    // Split at row 5
    const split_pin: Pin = .{ .node = original_node, .y = 5, .x = 0 };
    try s.split(split_pin);

    const first_page = s.pages.first.?;
    const second_page = first_page.next.?;

    // Pin before split point stays in original page
    try testing.expect(pin_before.node == first_page);
    try testing.expectEqual(@as(usize, 1), pin_before.y);
    try testing.expectEqual(@as(usize, 0), pin_before.x);

    // Pin at split point moves to new page with y=0
    try testing.expect(pin_at_split.node == second_page);
    try testing.expectEqual(@as(usize, 0), pin_at_split.y);
    try testing.expectEqual(@as(usize, 2), pin_at_split.x);

    // Pins after split point move to new page with adjusted y
    try testing.expect(pin_after1.node == second_page);
    try testing.expectEqual(@as(usize, 2), pin_after1.y); // 7 - 5 = 2
    try testing.expectEqual(@as(usize, 3), pin_after1.x);

    try testing.expect(pin_after2.node == second_page);
    try testing.expectEqual(@as(usize, 4), pin_after2.y); // 9 - 5 = 4
    try testing.expectEqual(@as(usize, 8), pin_after2.x);
}

test "PageList split tracked viewport_pin in split region moves correctly" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    const original_node = s.pages.first.?;

    // Set viewport_pin to row 7 (after split point)
    s.viewport_pin.node = original_node;
    s.viewport_pin.y = 7;
    s.viewport_pin.x = 6;

    // Split at row 5
    const split_pin: Pin = .{ .node = original_node, .y = 5, .x = 0 };
    try s.split(split_pin);

    // viewport_pin should be in the new page
    try testing.expect(s.viewport_pin.node == s.pages.first.?.next.?);
    // y should be adjusted: 7 - 5 = 2
    try testing.expectEqual(@as(usize, 2), s.viewport_pin.y);
    // x should remain unchanged
    try testing.expectEqual(@as(usize, 6), s.viewport_pin.x);
}
