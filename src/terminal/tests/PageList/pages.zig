//! PageList pages regression tests.
const support = @import("support.zig");
const PageList = support.PageList;
const std = support.std;
const stylepkg = support.stylepkg;
const size = support.size;
const Page = support.Page;
const List = support.List;
const std_size = support.std_size;
const Viewport = support.Viewport;
const init = support.init;
const totalRows = support.totalRows;
const growRows = support.growRows;
const markDirty = support.markDirty;
const Pin = support.Pin;
const TestSupport = support.TestSupport;

test "PageList Builder transfers mixed-width pages" {
    const testing = std.testing;

    // Build two populated pages whose widths differ from each other and from
    // the final active-area width. The first page also includes one row of
    // incidental history above the three-row active area.
    var result: PageList = result: {
        var builder = try TestSupport.Builder.init(testing.allocator, .{
            .cols = 4,
            .rows = 3,
            .max_size = null,
            .max_lines = null,
        });
        defer builder.deinit();

        const first = try builder.allocatePage(.{
            .cols = 2,
            .rows = 2,
        });
        first.size.rows = 2;
        first.getRowAndCell(0, 0).cell.* = .init('A');

        const second = try builder.allocatePage(.{
            .cols = 4,
            .rows = 2,
        });
        second.size.rows = 2;
        second.getRowAndCell(0, 0).cell.* = .init('B');

        break :result try builder.finish();
    };
    defer result.deinit();

    // Successful finish transfers ownership and initializes the PageList's
    // desired geometry, viewport, and required tracked viewport pin.
    try testing.expectEqual(@as(size.CellCountInt, 4), result.cols);
    try testing.expectEqual(@as(size.CellCountInt, 3), result.rows);
    try testing.expectEqual(@as(usize, 2), result.totalPages());
    try testing.expectEqual(@as(usize, 1), result.countTrackedPins());
    try testing.expectEqual(Viewport.active, result.viewport);

    // Complete pages and their contents are preserved in insertion order,
    // including widths which have not yet been reflowed.
    const screen_top = result.getTopLeft(.screen);
    try testing.expectEqual(@as(size.CellCountInt, 2), screen_top.node.cols());
    try testing.expectEqual(@as(u21, 'A'), screen_top
        .node.page().getRowAndCell(0, 0).cell.codepoint());

    // The active area is calculated backward from the newest page, so it
    // begins at row one of the oldest page and leaves row zero as history.
    const active_top = result.getTopLeft(.active);
    try testing.expectEqual(screen_top.node, active_top.node);
    try testing.expectEqual(@as(size.CellCountInt, 1), active_top.y);
    try testing.expectEqual(@as(size.CellCountInt, 4), active_top
        .node.next.?.cols());
    try testing.expectEqual(@as(u21, 'B'), active_top
        .node.next.?.page().getRowAndCell(0, 0).cell.codepoint());

    result.assertIntegrity();
}

test "PageList Builder validates the finished list" {
    const testing = std.testing;

    // The desired PageList geometry must describe a non-empty screen.
    {
        var builder = try TestSupport.Builder.init(testing.allocator, .{
            .cols = 0,
            .rows = 1,
        });
        defer builder.deinit();
        try testing.expectError(error.InvalidDimensions, builder.finish());
    }

    // A PageList cannot be finished without any backing pages.
    {
        var builder = try TestSupport.Builder.init(testing.allocator, .{
            .cols = 1,
            .rows = 1,
        });
        defer builder.deinit();
        try testing.expectError(error.NoPages, builder.finish());
    }

    // Allocated capacity alone is insufficient: callers must populate a
    // nonzero logical page size before transferring ownership.
    {
        var builder = try TestSupport.Builder.init(testing.allocator, .{
            .cols = 1,
            .rows = 1,
        });
        defer builder.deinit();
        const page = try builder.allocatePage(.{ .cols = 1, .rows = 1 });
        page.size.rows = 0;
        try testing.expectError(
            error.InvalidPageDimensions,
            builder.finish(),
        );
    }

    // The populated pages must contain enough rows to cover the active area.
    {
        var builder = try TestSupport.Builder.init(testing.allocator, .{
            .cols = 1,
            .rows = 2,
        });
        defer builder.deinit();
        const page = try builder.allocatePage(.{ .cols = 1, .rows = 1 });
        page.size.rows = 1;
        try testing.expectError(error.InsufficientRows, builder.finish());
    }
}

test "PageList Builder finish is transactional on allocation failure" {
    const testing = std.testing;

    // Construct a valid builder so finish reaches its fallible bookkeeping
    // allocations after all page and geometry validation succeeds.
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var builder = try TestSupport.Builder.init(failing.allocator(), .{
        .cols = 1,
        .rows = 1,
    });
    defer builder.deinit();
    const page = try builder.allocatePage(.{ .cols = 1, .rows = 1 });
    page.size.rows = 1;

    // The pools are preheated, so the next general allocation is the tracked
    // viewport pin map created by finish.
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, builder.finish());
    try testing.expect(failing.has_induced_failure);

    // Failed finish leaves page ownership with the builder so its normal
    // deinit path can release the still-linked page.
    try testing.expect(builder.pages.first != null);
    try testing.expectEqual(builder.pages.first, builder.pages.last);
}

test "PageList PageAllocation finalizes pages and preserves live state" {
    const testing = std.testing;

    // Build an existing list with history, a two-row active area, an external
    // active pin, and a pinned viewport whose absolute offset is cached.
    var result: PageList = result: {
        var builder = try TestSupport.Builder.init(testing.allocator, .{
            .cols = 4,
            .rows = 2,
            .max_size = null,
            .max_lines = null,
        });
        defer builder.deinit();

        const first = try builder.allocatePage(.{ .cols = 3, .rows = 2 });
        first.size.rows = 2;
        first.getRowAndCell(0, 0).cell.* = .init('C');

        const second = try builder.allocatePage(.{ .cols = 4, .rows = 2 });
        second.size.rows = 2;
        second.getRowAndCell(0, 0).cell.* = .init('D');

        break :result try builder.finish();
    };
    defer result.deinit();

    const old_first = result.pages.first.?;
    const old_last = result.pages.last.?;
    const active_top = result.getTopLeft(.active);
    const tracked_active = try result.trackPin(active_top);
    result.scroll(.{ .row = 1 });
    try testing.expectEqual(Viewport.pin, result.viewport);
    try testing.expectEqual(@as(usize, 1), result.scrollbar().offset);

    // Prepend differently sized historical pages newest-first. Each page is
    // populated while detached and joins the live list only on success.
    {
        var allocation = try TestSupport.allocatePage(&result, .{ .cols = 4, .rows = 1 });
        defer allocation.deinit();
        const page = allocation.page();
        page.size.rows = 1;
        page.getRowAndCell(0, 0).cell.* = .init('B');
        try allocation.finalize(.prepend);
    }
    {
        var allocation = try TestSupport.allocatePage(&result, .{ .cols = 2, .rows = 2 });
        defer allocation.deinit();
        const page = allocation.page();
        page.size.rows = 2;
        page.getRowAndCell(0, 0).cell.* = .init('A');
        try allocation.finalize(.prepend);
    }

    // Repeated prepends reconstruct oldest-to-newest order without replacing
    // any existing nodes or tracked pins.
    try testing.expectEqual(@as(usize, 4), result.totalPages());
    try testing.expectEqual(@as(usize, 7), result.total_rows);
    try testing.expectEqual(old_last, result.pages.last.?);
    try testing.expectEqual(old_first, result.pages.first.?.next.?.next.?);
    try testing.expectEqual(
        @as(u21, 'A'),
        result.pages.first.?.page().getRowAndCell(0, 0).cell.codepoint(),
    );
    try testing.expectEqual(
        @as(u21, 'B'),
        result.pages.first.?.next.?
            .page().getRowAndCell(0, 0).cell.codepoint(),
    );
    try testing.expect(active_top.eql(result.getTopLeft(.active)));
    try testing.expect(active_top.eql(tracked_active.*));

    // The viewport remains pinned to the same content, while its cached row
    // offset and the scrollbar total include the three new historical rows.
    try testing.expectEqual(Viewport.pin, result.viewport);
    try testing.expectEqual(old_first, result.viewport_pin.node);
    try testing.expectEqual(@as(size.CellCountInt, 1), result.viewport_pin.y);
    const scrollbar_state = result.scrollbar();
    try testing.expectEqual(@as(usize, 7), scrollbar_state.total);
    try testing.expectEqual(@as(usize, 4), scrollbar_state.offset);
    try testing.expectEqual(@as(usize, 2), scrollbar_state.len);

    result.assertIntegrity();
}

test "PageList PageAllocation stays detached until finalize" {
    const testing = std.testing;

    var result = try init(testing.allocator, .{
        .cols = 1,
        .rows = 1,
        .max_size = null,
        .max_lines = null,
    });
    defer result.deinit();

    const initial_first = result.pages.first.?;
    const initial_last = result.pages.last.?;
    const initial_total_rows = result.total_rows;
    const initial_page_size = result.page_size;

    // Allocating and populating a detached page does not alter any live list
    // links or accounting. Deinit returns it to the same PageList pools.
    var detached = try TestSupport.allocatePage(&result, .{ .cols = 1, .rows = 1 });
    detached.page().size.rows = 1;
    try testing.expectEqual(initial_first, result.pages.first.?);
    try testing.expectEqual(initial_last, result.pages.last.?);
    try testing.expectEqual(initial_total_rows, result.total_rows);
    try testing.expectEqual(initial_page_size, result.page_size);
    result.assertIntegrity();
    detached.deinit();
    result.assertIntegrity();

    // Invalid populated dimensions leave ownership with the allocation so it
    // can still be released normally.
    var invalid = try TestSupport.allocatePage(&result, .{ .cols = 1, .rows = 1 });
    defer invalid.deinit();
    try testing.expectError(
        error.InvalidPageDimensions,
        invalid.finalize(.prepend),
    );

    try testing.expectEqual(initial_first, result.pages.first.?);
    try testing.expectEqual(initial_last, result.pages.last.?);
    try testing.expectEqual(initial_total_rows, result.total_rows);
    try testing.expectEqual(initial_page_size, result.page_size);
    result.assertIntegrity();
}

test "PageList PageAllocation allocation failure leaves list unchanged" {
    const testing = std.testing;

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var result = try init(failing.allocator(), .{
        .cols = 1,
        .rows = 1,
        .max_size = null,
        .max_lines = null,
    });
    defer result.deinit();

    const initial_first = result.pages.first.?;
    const initial_total_rows = result.total_rows;
    const initial_page_size = result.page_size;

    // Existing pool capacity is deliberately an implementation detail. Allow
    // preheated slots to succeed until allocation reaches node-pool growth.
    failing.fail_index = failing.alloc_index;
    var allocations: [64]TestSupport.PageAllocation = undefined;
    var allocation_count: usize = 0;
    defer for (allocations[0..allocation_count]) |*allocation| {
        allocation.deinit();
    };

    var failed = false;
    for (0..64) |_| {
        allocations[allocation_count] = TestSupport.allocatePage(&result, .{
            .cols = 1,
            .rows = 1,
        }) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failed = true;
            break;
        };
        allocation_count += 1;
    }
    try testing.expect(failed);
    try testing.expect(failing.has_induced_failure);

    // Detached allocations and failed pool growth never publish into the live
    // list; the deferred cleanup returns every successful allocation.
    try testing.expectEqual(initial_first, result.pages.first.?);
    try testing.expectEqual(initial_total_rows, result.total_rows);
    try testing.expectEqual(initial_page_size, result.page_size);
    result.assertIntegrity();
}

test "PageList erase" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

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
    try testing.expectEqual(@as(usize, 6), s.totalPages());

    // Our total rows should be large
    try testing.expect(s.total_rows > s.rows);

    // Erase the entire history, we should be back to just our active set.
    s.eraseHistory(null);
    try testing.expectEqual(s.rows, s.total_rows);

    // We should be back to just one page
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    try testing.expect(s.pages.first == s.pages.last);
}

test "PageList erase reaccounts page size" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const start_size = s.page_size;

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
    try testing.expect(s.page_size > start_size);

    // Erase the entire history, we should be back to just our active set.
    s.eraseHistory(null);
    try testing.expectEqual(start_size, s.page_size);
}

test "PageList erase a one-row active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 1 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Write our letter
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }

    s.eraseActive(0);
    try testing.expectEqual(s.rows, s.total_rows);

    // The row should be empty
    {
        const get = s.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expectEqual(@as(u21, 0), get.cell.content.codepoint.data);
    }
}

test "PageList eraseRowBounded less than full row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 10 });
    defer s.deinit();

    // Pins
    const p_top = try s.trackPin(s.pin(.{ .active = .{ .y = 5, .x = 0 } }).?);
    defer s.untrackPin(p_top);
    const p_bot = try s.trackPin(s.pin(.{ .active = .{ .y = 8, .x = 0 } }).?);
    defer s.untrackPin(p_bot);
    const p_out = try s.trackPin(s.pin(.{ .active = .{ .y = 9, .x = 0 } }).?);
    defer s.untrackPin(p_out);

    // Erase only a few rows in our active
    try s.eraseRowBounded(.{ .active = .{ .y = 5 } }, 3);
    try testing.expectEqual(s.rows, totalRows(&s));

    // The erased rows should be dirty
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 5 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 6 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 7 } }));

    try testing.expectEqual(s.pages.first.?, p_top.node);
    try testing.expectEqual(@as(usize, 4), p_top.y);
    try testing.expectEqual(@as(usize, 0), p_top.x);

    try testing.expectEqual(s.pages.first.?, p_bot.node);
    try testing.expectEqual(@as(usize, 7), p_bot.y);
    try testing.expectEqual(@as(usize, 0), p_bot.x);

    try testing.expectEqual(s.pages.first.?, p_out.node);
    try testing.expectEqual(@as(usize, 9), p_out.y);
    try testing.expectEqual(@as(usize, 0), p_out.x);
}

test "PageList eraseRowBounded full rows single page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 10 });
    defer s.deinit();

    // Pins
    const p_in = try s.trackPin(s.pin(.{ .active = .{ .y = 7, .x = 0 } }).?);
    defer s.untrackPin(p_in);
    const p_out = try s.trackPin(s.pin(.{ .active = .{ .y = 9, .x = 0 } }).?);
    defer s.untrackPin(p_out);

    // Erase only a few rows in our active
    try s.eraseRowBounded(.{ .active = .{ .y = 5 } }, 10);
    try testing.expectEqual(s.rows, totalRows(&s));

    // The erased rows should be dirty
    for (5..10) |y| try testing.expect(s.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    // Our pin should move to the first page
    try testing.expectEqual(s.pages.first.?, p_in.node);
    try testing.expectEqual(@as(usize, 6), p_in.y);
    try testing.expectEqual(@as(usize, 0), p_in.x);

    try testing.expectEqual(s.pages.first.?, p_out.node);
    try testing.expectEqual(@as(usize, 8), p_out.y);
    try testing.expectEqual(@as(usize, 0), p_out.x);
}

test "PageList eraseRowBounded full rows two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 10 });
    defer s.deinit();

    // Grow to two pages so our active area straddles
    {
        const page = s.pages.last.?.page();
        page.pauseIntegrityChecks(true);
        for (0..page.capacity.rows - page.size.rows) |_| _ = try s.grow();
        page.pauseIntegrityChecks(false);
        try growRows(&s, 5);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
        try testing.expectEqual(@as(usize, 5), s.pages.last.?.rows());
    }

    // Pins
    const p_first = try s.trackPin(s.pin(.{ .active = .{ .y = 4, .x = 0 } }).?);
    defer s.untrackPin(p_first);
    const p_first_out = try s.trackPin(s.pin(.{ .active = .{ .y = 3, .x = 0 } }).?);
    defer s.untrackPin(p_first_out);
    const p_in = try s.trackPin(s.pin(.{ .active = .{ .y = 8, .x = 0 } }).?);
    defer s.untrackPin(p_in);
    const p_out = try s.trackPin(s.pin(.{ .active = .{ .y = 9, .x = 0 } }).?);
    defer s.untrackPin(p_out);

    {
        try testing.expectEqual(s.pages.last.?.prev.?, p_first.node);
        try testing.expectEqual(@as(usize, p_first.node.rows() - 1), p_first.y);
        try testing.expectEqual(@as(usize, 0), p_first.x);

        try testing.expectEqual(s.pages.last.?.prev.?, p_first_out.node);
        try testing.expectEqual(@as(usize, p_first_out.node.rows() - 2), p_first_out.y);
        try testing.expectEqual(@as(usize, 0), p_first_out.x);

        try testing.expectEqual(s.pages.last.?, p_in.node);
        try testing.expectEqual(@as(usize, 3), p_in.y);
        try testing.expectEqual(@as(usize, 0), p_in.x);

        try testing.expectEqual(s.pages.last.?, p_out.node);
        try testing.expectEqual(@as(usize, 4), p_out.y);
        try testing.expectEqual(@as(usize, 0), p_out.x);
    }

    // Erase only a few rows in our active
    try s.eraseRowBounded(.{ .active = .{ .y = 4 } }, 4);

    // The erased rows should be dirty
    for (4..8) |y| try testing.expect(s.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    // In page in first page is shifted
    try testing.expectEqual(s.pages.last.?.prev.?, p_first.node);
    try testing.expectEqual(@as(usize, p_first.node.rows() - 2), p_first.y);
    try testing.expectEqual(@as(usize, 0), p_first.x);

    // Out page in first page should not be shifted
    try testing.expectEqual(s.pages.last.?.prev.?, p_first_out.node);
    try testing.expectEqual(@as(usize, p_first_out.node.rows() - 2), p_first_out.y);
    try testing.expectEqual(@as(usize, 0), p_first_out.x);

    // In page is shifted
    try testing.expectEqual(s.pages.last.?, p_in.node);
    try testing.expectEqual(@as(usize, 2), p_in.y);
    try testing.expectEqual(@as(usize, 0), p_in.x);

    // Out page is not shifted
    try testing.expectEqual(s.pages.last.?, p_out.node);
    try testing.expectEqual(@as(usize, 4), p_out.y);
    try testing.expectEqual(@as(usize, 0), p_out.x);
}

test "PageList eraseRow hyperlink-dense row crosses page boundary" {
    // Regression test: when eraseRow shifts rows up across a page
    // boundary, the top row of the next page is cloned into the last
    // row of the previous page. If the previous page doesn't have
    // enough capacity for the managed memory of that row (hyperlinks,
    // styles, etc.) the error propagated out AFTER the previous page
    // had already been rotated and its tracked pins moved, leaving
    // the page list half-mutated.
    //
    // eraseRow must instead increase the destination page's capacity
    // and retry, the same way insertLines/deleteLines and
    // cursorScrollAbove handle their cross-page copies.
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 10 });
    defer s.deinit();

    // Grow to two pages so our active area straddles them: the first
    // page is exactly full and the second page holds the last 5 rows
    // of the active area.
    {
        const page = s.pages.last.?.page();
        page.pauseIntegrityChecks(true);
        for (0..page.capacity.rows - page.size.rows) |_| _ = try s.grow();
        page.pauseIntegrityChecks(false);
        try growRows(&s, 5);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
        try testing.expectEqual(@as(usize, 5), s.pages.last.?.rows());
    }

    // Mark each active row with a codepoint so we can verify the
    // shift afterwards. Row y gets codepoint '0' + y at x = 0.
    for (0..10) |y| {
        const row_pin = s.pin(.{ .active = .{ .y = @intCast(y) } }).?;
        row_pin.rowAndCell().cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast('0' + y) } },
        };
    }

    // Fill the top row of the second page (active y=5) with more
    // unique hyperlinks ('A' through 'J') than the first page's
    // default hyperlink capacity can hold. We must increase the
    // second page's capacity to even create such a row; the first
    // page keeps its default capacity.
    const link_count: usize = 10;
    while (s.pages.last.?.page().hyperlink_set.layout.cap <= link_count) {
        _ = try s.increaseCapacity(s.pages.last.?, .hyperlink_bytes);
    }
    try testing.expect(s.pages.first.?.page().hyperlink_set.layout.cap < link_count);
    {
        const page = s.pages.last.?.page();
        for (0..link_count) |x| {
            var buf: [64]u8 = undefined;
            const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{x});
            const id = try page.insertHyperlink(.{
                .id = .{ .implicit = @intCast(x) },
                .uri = uri,
            });
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast('A' + x) } },
            };
            try page.setHyperlink(rac.row, rac.cell, id);
            page.hyperlink_set.use(page.memory, id);
        }
    }

    // Track a pin in the shifted region of the first page to verify
    // it survives the capacity change of its node.
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 3, .y = 1 } }).?);
    defer s.untrackPin(p);

    // Erase the first active row. The dense hyperlink row must cross
    // the page boundary into the first page, which requires growing
    // the first page's hyperlink capacity.
    try s.eraseRow(.{ .active = .{ .y = 0 } });

    // Every remaining row shifted up by one: the '0' marker row was
    // erased, the dense row moved up across the page boundary to
    // row 4, and the last row was cleared.
    const expected = [10]u21{ '1', '2', '3', '4', 'A', '6', '7', '8', '9', 0 };
    for (expected, 0..) |cp, y| {
        const list_cell = s.getCell(.{ .active = .{ .y = @intCast(y) } }).?;
        try testing.expectEqual(cp, list_cell.cell.content.codepoint.data);
    }

    // Every cell of the dense row must still resolve to a real
    // hyperlink entry with the correct URI. A half-applied erase
    // leaves cells whose hyperlink flag is set but that have no map
    // entry, which aborts in clearCells later.
    for (0..link_count) |x| {
        const list_cell = s.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 4,
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
    var node_: ?*List.Node = s.pages.first;
    while (node_) |node| : (node_ = node.next) node.page().assertIntegrity();

    // Our tracked pin shifted up by one row and still points into
    // the (possibly replaced) first page.
    try testing.expectEqual(s.pages.first.?, p.node);
    const p_pt = s.pointFromPin(.active, p.*).?.active;
    try testing.expectEqual(@as(u32, 3), p_pt.x);
    try testing.expectEqual(@as(u32, 0), p_pt.y);
}

test "PageList eraseRowBounded hyperlink-dense row crosses page boundary" {
    // Same as the eraseRow variant above but for eraseRowBounded,
    // which has the same rotate-then-clone structure and had the
    // same bug: a cross-page row clone failure propagated out after
    // the first page had already been rotated.
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 10 });
    defer s.deinit();

    // Grow to two pages so our active area straddles them: the first
    // page is exactly full and the second page holds the last 5 rows
    // of the active area.
    {
        const page = s.pages.last.?.page();
        page.pauseIntegrityChecks(true);
        for (0..page.capacity.rows - page.size.rows) |_| _ = try s.grow();
        page.pauseIntegrityChecks(false);
        try growRows(&s, 5);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
        try testing.expectEqual(@as(usize, 5), s.pages.last.?.rows());
    }

    // Mark each active row with a codepoint so we can verify the
    // shift afterwards. Row y gets codepoint '0' + y at x = 0.
    for (0..10) |y| {
        const row_pin = s.pin(.{ .active = .{ .y = @intCast(y) } }).?;
        row_pin.rowAndCell().cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast('0' + y) } },
        };
    }

    // Fill the top row of the second page (active y=5) with more
    // unique hyperlinks ('A' through 'J') than the first page's
    // default hyperlink capacity can hold. We must increase the
    // second page's capacity to even create such a row; the first
    // page keeps its default capacity.
    const link_count: usize = 10;
    while (s.pages.last.?.page().hyperlink_set.layout.cap <= link_count) {
        _ = try s.increaseCapacity(s.pages.last.?, .hyperlink_bytes);
    }
    try testing.expect(s.pages.first.?.page().hyperlink_set.layout.cap < link_count);
    {
        const page = s.pages.last.?.page();
        for (0..link_count) |x| {
            var buf: [64]u8 = undefined;
            const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{x});
            const id = try page.insertHyperlink(.{
                .id = .{ .implicit = @intCast(x) },
                .uri = uri,
            });
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast('A' + x) } },
            };
            try page.setHyperlink(rac.row, rac.cell, id);
            page.hyperlink_set.use(page.memory, id);
        }
    }

    // Erase the first active row with a limit that extends into the
    // second page (5 rows remain in the first page, so a limit of 6
    // forces the cross-page path). The dense hyperlink row must cross
    // the page boundary into the first page.
    try s.eraseRowBounded(.{ .active = .{ .y = 0 } }, 6);

    // Rows within the limit shifted up by one: the '0' marker row was
    // erased, the dense row moved up across the page boundary to
    // row 4, row 6 is the new blank row, and rows past the limit are
    // unchanged.
    const expected = [10]u21{ '1', '2', '3', '4', 'A', '6', 0, '7', '8', '9' };
    for (expected, 0..) |cp, y| {
        const list_cell = s.getCell(.{ .active = .{ .y = @intCast(y) } }).?;
        try testing.expectEqual(cp, list_cell.cell.content.codepoint.data);
    }

    // Every cell of the dense row must still resolve to a real
    // hyperlink entry with the correct URI. A half-applied erase
    // leaves cells whose hyperlink flag is set but that have no map
    // entry, which aborts in clearCells later.
    for (0..link_count) |x| {
        const list_cell = s.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 4,
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
    var node_: ?*List.Node = s.pages.first;
    while (node_) |node| : (node_ = node.next) node.page().assertIntegrity();
}

test "PageList clone" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s2));
}

test "PageList clone partial trimmed right" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 20 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));
    try growRows(&s, 30);

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
        .bot = .{ .screen = .{ .y = 39 } },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 40), totalRows(&s2));
}

test "PageList clone partial trimmed left" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 20 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));
    try growRows(&s, 30);

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{ .y = 10 } },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 40), totalRows(&s2));
}

test "PageList clone partial trimmed left reclaims styles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 20 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));
    try growRows(&s, 30);

    // Style the rows we're trimming
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        const style: stylepkg.Style = .{ .flags = .{ .bold = true } };
        const style_id = try page.styles.add(page.memory, style);

        var it = s.rowIterator(.left_up, .{ .screen = .{} }, .{ .screen = .{ .y = 9 } });
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            rac.row.styled = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
                .style_id = style_id,
            };
            page.styles.use(page.memory, style_id);
        }

        // We're over-counted by 1 because `add` implies `use`.
        page.styles.release(page.memory, style_id);

        // Expect to have one style
        try testing.expectEqual(1, page.styles.count());
    }

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{ .y = 10 } },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 40), totalRows(&s2));

    {
        try testing.expect(s2.pages.first == s2.pages.last);
        const page = s2.pages.first.?.page();
        try testing.expectEqual(0, page.styles.count());
    }
}

test "PageList clone partial trimmed both" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 20 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));
    try growRows(&s, 30);

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{ .y = 10 } },
        .bot = .{ .screen = .{ .y = 35 } },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 26), totalRows(&s2));
}

test "PageList clone less than active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));

    var s2 = try s.clone(alloc, .{
        .top = .{ .active = .{ .y = 5 } },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s2));
}

test "PageList clone full dirty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));

    // Mark a row as dirty
    markDirty(&s, .{ .active = .{ .x = 0, .y = 0 } });
    markDirty(&s, .{ .active = .{ .x = 0, .y = 12 } });
    markDirty(&s, .{ .active = .{ .x = 0, .y = 23 } });

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s2));

    // Should still be dirty
    try testing.expect(s2.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!s2.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s2.isDirty(.{ .active = .{ .x = 0, .y = 12 } }));
    try testing.expect(!s2.isDirty(.{ .active = .{ .x = 0, .y = 14 } }));
    try testing.expect(s2.isDirty(.{ .active = .{ .x = 0, .y = 23 } }));
}

test "PageList compact then clone" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Write a marker so we can verify contents survive.
    {
        const node = s.pages.first.?;
        const rac = node.page().getRowAndCell(1, 2);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'X' } },
        };
    }

    // Compact so the source list contains a sub-std_size heap page.
    const node = (try s.compact(s.pages.first.?)).?;
    try testing.expectEqual(.heap, node.owned);
    try testing.expect(node.page().memory.len < std_size);

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s2));

    // Verify the marker survived the clone.
    {
        const node2 = s2.pages.first.?;
        const rac = node2.page().getRowAndCell(1, 2);
        try testing.expectEqual(@as(u21, 'X'), rac.cell.content.codepoint.data);
    }
}

test "PageList split at middle row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Write content to rows: row 0 gets codepoint 0, row 1 gets 1, etc.
    for (0..page.size.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }

    // Split at row 5 (middle)
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);

    // Verify two pages exist
    try testing.expect(s.pages.first != null);
    try testing.expect(s.pages.first.?.next != null);

    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();

    // First page should have rows 0-4 (5 rows)
    try testing.expectEqual(@as(usize, 5), first_page.size.rows);
    // Second page should have rows 5-9 (5 rows)
    try testing.expectEqual(@as(usize, 5), second_page.size.rows);

    // Verify content in first page is preserved (rows 0-4 have codepoints 0-4)
    for (0..5) |y| {
        const rac = first_page.getRowAndCell(0, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint.data);
    }

    // Verify content in second page (original rows 5-9, now at y=0-4)
    for (0..5) |y| {
        const rac = second_page.getRowAndCell(0, y);
        try testing.expectEqual(@as(u21, @intCast(y + 5)), rac.cell.content.codepoint.data);
    }
}

test "PageList split at row 0 is no-op" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Write content to all rows
    for (0..page.size.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }

    // Split at row 0 should be a no-op
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 0, .x = 0 };
    try s.split(split_pin);

    // Verify only one page exists (no split occurred)
    try testing.expect(s.pages.first != null);
    try testing.expect(s.pages.first.?.next == null);

    // Verify all content is still in the original page
    try testing.expectEqual(@as(usize, 10), page.size.rows);
    for (0..10) |y| {
        const rac = page.getRowAndCell(0, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint.data);
    }
}

test "PageList split at last row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Write content to all rows
    for (0..page.size.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }

    // Split at last row (row 9)
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 9, .x = 0 };
    try s.split(split_pin);

    // Verify two pages exist
    try testing.expect(s.pages.first != null);
    try testing.expect(s.pages.first.?.next != null);

    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();

    // First page should have 9 rows
    try testing.expectEqual(@as(usize, 9), first_page.size.rows);
    // Second page should have 1 row
    try testing.expectEqual(@as(usize, 1), second_page.size.rows);

    // Verify content in second page (original row 9, now at y=0)
    const rac = second_page.getRowAndCell(0, 0);
    try testing.expectEqual(@as(u21, 9), rac.cell.content.codepoint.data);
}

test "PageList split single row page returns OutOfSpace" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize with 1 row
    var s = try init(alloc, .{ .cols = 10, .rows = 1, .max_size = 0 });
    defer s.deinit();

    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 0, .x = 0 };
    const result = s.split(split_pin);

    try testing.expectError(error.OutOfSpace, result);
}

test "PageList split middle page preserves linked list order" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Create a single page with 12 rows
    var s = try init(alloc, .{ .cols = 10, .rows = 12, .max_size = 0 });
    defer s.deinit();

    // Split at row 4 to create: page1 (rows 0-3), page2 (rows 4-11)
    const first_node = s.pages.first.?;
    const split_pin1: Pin = .{ .node = first_node, .y = 4, .x = 0 };
    try s.split(split_pin1);

    // Now we have 2 pages
    const page1 = s.pages.first.?;
    const page2 = s.pages.first.?.next.?;
    try testing.expectEqual(@as(usize, 4), page1.rows());
    try testing.expectEqual(@as(usize, 8), page2.rows());

    // Split page2 at row 4 to create: page1 -> page2 (rows 0-3) -> page3 (rows 4-7)
    const split_pin2: Pin = .{ .node = page2, .y = 4, .x = 0 };
    try s.split(split_pin2);

    // Now we have 3 pages
    const first = s.pages.first.?;
    const middle = first.next.?;
    const last = middle.next.?;

    // Verify linked list order: first -> middle -> last
    try testing.expectEqual(page1, first);
    try testing.expectEqual(page2, middle);
    try testing.expectEqual(s.pages.last.?, last);

    // Verify prev pointers
    try testing.expect(first.prev == null);
    try testing.expectEqual(first, middle.prev.?);
    try testing.expectEqual(middle, last.prev.?);

    // Verify next pointers
    try testing.expectEqual(middle, first.next.?);
    try testing.expectEqual(last, middle.next.?);
    try testing.expect(last.next == null);

    // Verify row counts
    try testing.expectEqual(@as(usize, 4), first.rows());
    try testing.expectEqual(@as(usize, 4), middle.rows());
    try testing.expectEqual(@as(usize, 4), last.rows());
}

test "PageList split last page makes new page the last" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Create a single page with 10 rows
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    // Split to create 2 pages first
    const first_node = s.pages.first.?;
    const split_pin1: Pin = .{ .node = first_node, .y = 5, .x = 0 };
    try s.split(split_pin1);

    // Now split the last page
    const last_before_split = s.pages.last.?;
    try testing.expectEqual(@as(usize, 5), last_before_split.rows());

    const split_pin2: Pin = .{ .node = last_before_split, .y = 2, .x = 0 };
    try s.split(split_pin2);

    // The new page should be the new last
    const new_last = s.pages.last.?;
    try testing.expect(new_last != last_before_split);
    try testing.expectEqual(last_before_split, new_last.prev.?);
    try testing.expect(new_last.next == null);

    // Verify row counts: original last has 2 rows, new last has 3 rows
    try testing.expectEqual(@as(usize, 2), last_before_split.rows());
    try testing.expectEqual(@as(usize, 3), new_last.rows());
}

test "PageList split first page keeps original as first" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Create 2 pages by splitting
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    const original_first = s.pages.first.?;
    const split_pin1: Pin = .{ .node = original_first, .y = 5, .x = 0 };
    try s.split(split_pin1);

    // Get second page (created by first split)
    const second_page = s.pages.first.?.next.?;

    // Now split the first page again
    const split_pin2: Pin = .{ .node = s.pages.first.?, .y = 2, .x = 0 };
    try s.split(split_pin2);

    // Original first should still be first
    try testing.expectEqual(original_first, s.pages.first.?);
    try testing.expect(s.pages.first.?.prev == null);

    // New page should be inserted between first and second
    const inserted = s.pages.first.?.next.?;
    try testing.expect(inserted != second_page);
    try testing.expectEqual(second_page, inserted.next.?);

    // Verify row counts: first has 2, inserted has 3, second has 5
    try testing.expectEqual(@as(usize, 2), s.pages.first.?.rows());
    try testing.expectEqual(@as(usize, 3), inserted.rows());
    try testing.expectEqual(@as(usize, 5), second_page.rows());
}

test "PageList split preserves wrap flags" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Set wrap flags on rows that will be in the second page after split
    // Row 5: wrap = true (this is the start of a wrapped line)
    // Row 6: wrap_continuation = true (this continues the wrap)
    // Row 7: wrap = true, wrap_continuation = true (wrapped and continues)
    {
        const rac5 = page.getRowAndCell(0, 5);
        rac5.row.wrap = true;

        const rac6 = page.getRowAndCell(0, 6);
        rac6.row.wrap_continuation = true;

        const rac7 = page.getRowAndCell(0, 7);
        rac7.row.wrap = true;
        rac7.row.wrap_continuation = true;
    }

    // Split at row 5
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);

    const second_page = s.pages.first.?.next.?.page();

    // Verify wrap flags are preserved in new page
    // Original row 5 is now row 0 in second page
    {
        const rac0 = second_page.getRowAndCell(0, 0);
        try testing.expect(rac0.row.wrap);
        try testing.expect(!rac0.row.wrap_continuation);
    }

    // Original row 6 is now row 1 in second page
    {
        const rac1 = second_page.getRowAndCell(0, 1);
        try testing.expect(!rac1.row.wrap);
        try testing.expect(rac1.row.wrap_continuation);
    }

    // Original row 7 is now row 2 in second page
    {
        const rac2 = second_page.getRowAndCell(0, 2);
        try testing.expect(rac2.row.wrap);
        try testing.expect(rac2.row.wrap_continuation);
    }
}

test "PageList split preserves styled cells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Create a style and apply it to cells in rows 5-7 (which will be in the second page)
    const style: stylepkg.Style = .{ .flags = .{ .bold = true } };
    const style_id = try page.styles.add(page.memory, style);

    for (5..8) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'S' } },
            .style_id = style_id,
        };
        rac.row.styled = true;
        page.styles.use(page.memory, style_id);
    }
    // Release the extra ref from add
    page.styles.release(page.memory, style_id);

    // Split at row 5
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);

    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();

    // First page should have no styles (all styled rows moved to second page)
    try testing.expectEqual(@as(usize, 0), first_page.styles.count());

    // Second page should have exactly 1 style (the bold style, used by 3 cells)
    try testing.expectEqual(@as(usize, 1), second_page.styles.count());

    // Verify styled cells are preserved in new page
    for (0..3) |y| {
        const rac = second_page.getRowAndCell(0, y);
        try testing.expectEqual(@as(u21, 'S'), rac.cell.content.codepoint.data);
        try testing.expect(rac.cell.style_id != 0);

        const got_style = second_page.styles.get(second_page.memory, rac.cell.style_id);
        try testing.expect(got_style.flags.bold);
        try testing.expect(rac.row.styled);
    }
}

test "PageList split preserves grapheme clusters" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Add a grapheme cluster to row 6 (will be row 1 in second page after split at 5)
    {
        const rac = page.getRowAndCell(0, 6);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 0x1F468 } }, // Man emoji
        };
        try page.setGraphemes(rac.row, rac.cell, &.{
            0x200D, // ZWJ
            0x1F469, // Woman emoji
        });
    }

    // Split at row 5
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);

    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();

    // First page should have no graphemes (the grapheme row moved to second page)
    try testing.expectEqual(@as(usize, 0), first_page.graphemeCount());

    // Second page should have exactly 1 grapheme
    try testing.expectEqual(@as(usize, 1), second_page.graphemeCount());

    // Verify grapheme is preserved in new page (original row 6 is now row 1)
    {
        const rac = second_page.getRowAndCell(0, 1);
        try testing.expectEqual(@as(u21, 0x1F468), rac.cell.content.codepoint.data);
        try testing.expect(rac.row.grapheme);

        const cps = second_page.lookupGrapheme(rac.cell).?;
        try testing.expectEqual(@as(usize, 2), cps.len);
        try testing.expectEqual(@as(u21, 0x200D), cps[0]);
        try testing.expectEqual(@as(u21, 0x1F469), cps[1]);
    }
}

test "PageList split preserves hyperlinks" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Add a hyperlink to row 7 (will be row 2 in second page after split at 5)
    const hyperlink_id = try page.insertHyperlink(.{
        .id = .{ .implicit = 0 },
        .uri = "https://example.com",
    });
    {
        const rac = page.getRowAndCell(0, 7);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'L' } },
        };
        try page.setHyperlink(rac.row, rac.cell, hyperlink_id);
    }

    // Split at row 5
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);

    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();

    // First page should have no hyperlinks (the hyperlink row moved to second page)
    try testing.expectEqual(@as(usize, 0), first_page.hyperlink_set.count());

    // Second page should have exactly 1 hyperlink
    try testing.expectEqual(@as(usize, 1), second_page.hyperlink_set.count());

    // Verify hyperlink is preserved in new page (original row 7 is now row 2)
    {
        const rac = second_page.getRowAndCell(0, 2);
        try testing.expectEqual(@as(u21, 'L'), rac.cell.content.codepoint.data);
        try testing.expect(rac.cell.hyperlink);

        const link_id = second_page.lookupHyperlink(rac.cell).?;
        const link = second_page.hyperlink_set.get(second_page.memory, link_id);
        try testing.expectEqualStrings("https://example.com", link.uri.slice(second_page.memory));
    }
}

test "PageList eraseRow recycled row has default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer s.deinit();

    // Simulate the top row being part of a soft-wrapped, prompt-marked
    // line. Erasing it recycles its Row storage as the new blank
    // bottom row, which must not retain any of this metadata.
    {
        const rac = s.getCell(.{ .active = .{} }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }

    try s.eraseRow(.{ .active = .{} });

    {
        const rac = s.getCell(.{ .active = .{ .y = 2 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}

test "PageList eraseRowBounded recycled row has default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A limit smaller than the remaining rows in the page exercises
    // the bounded-rotate branch; a larger limit exercises the fallback
    // branch that clears the final row after a full rotation.
    for ([_]usize{ 1, 10 }) |limit| {
        var s = try init(alloc, .{ .cols = 5, .rows = 3 });
        defer s.deinit();

        {
            const rac = s.getCell(.{ .active = .{} }).?;
            rac.row.wrap = true;
            rac.row.wrap_continuation = true;
            rac.row.semantic_prompt = .prompt;
        }

        try s.eraseRowBounded(.{ .active = .{} }, limit);

        const recycled_y = @min(limit, 2);
        const rac = s.getCell(.{ .active = .{ .y = @intCast(recycled_y) } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}

test "PageList split retired rows have default state" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 10 });
    defer s.deinit();

    // Put metadata and a background-colored (non-zero, but text-free)
    // cell on a row that the split will move to the new page. The
    // retired Row storage on the source page goes back into unused
    // capacity that grow() re-exposes without clearing.
    {
        const rac = s.getCell(.{ .active = .{ .y = 7 } }).?;
        rac.row.wrap = true;
        rac.row.semantic_prompt = .prompt;
        rac.cell.* = .{
            .content_tag = .bg_color_palette,
            .content = .{ .color_palette = .{ .data = 42 } },
        };
    }

    const node = s.pages.first.?;
    try s.split(s.pin(.{ .active = .{ .y = 5 } }).?);

    // The source page was truncated to 5 rows; peek at the retired
    // storage beyond size.rows.
    const page = node.page();
    try testing.expectEqual(@as(usize, 5), page.size.rows);
    const rows = page.rows.ptr(page.memory.ptr);
    for (5..10) |y| {
        const row = rows[y];
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);
        try testing.expectEqual(.none, row.semantic_prompt);
        const cells = row.cells.ptr(page.memory.ptr)[0..page.size.cols];
        for (cells) |cell| try testing.expect(cell.isZero());
    }
}
