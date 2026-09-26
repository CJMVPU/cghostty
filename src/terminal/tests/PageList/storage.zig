//! PageList storage regression tests.
const nodeMetadata = support.nodeMetadata;
const nodeIsCompressed = support.nodeIsCompressed;
const createPage = support.createPage;
const support = @import("support.zig");
const PageList = support.PageList;
const std = support.std;
const point = support.point;
const size = support.size;
const Page = support.Page;
const page_preheat = support.page_preheat;
const List = support.List;
const Node = support.Node;
const std_capacity = support.std_capacity;
const std_size = support.std_size;
const PagePool = support.PagePool;
const MemoryPool = support.MemoryPool;
const initialCapacity = support.initialCapacity;
const init = support.init;
const Scrollbar = support.Scrollbar;
const IncrementalCompressionState = support.IncrementalCompressionState;
const IncrementalCompressionResult = support.IncrementalCompressionResult;
const CompressionIterator = support.CompressionIterator;
const incremental_compression_max_inspected = support.incremental_compression_max_inspected;
const compressPage_tw = support.compressPage_tw;
const compressPage = support.compressPage;
const destroyNode = support.destroyNode;
const totalRows = support.totalRows;
const growRows = support.growRows;
const Pin = support.Pin;
const TestSupport = support.TestSupport;
const growColdPagesForTest = support.growColdPagesForTest;
const fillLastPageForTest = support.fillLastPageForTest;
const expectLivePageSerialsValidForTest = support.expectLivePageSerialsValidForTest;

test "PageList PageAllocation rejects limits before modifying the destination" {
    const testing = std.testing;

    var result = try init(testing.allocator, .{
        .cols = 1,
        .rows = 1,
        .max_size = 0,
        .max_lines = null,
    });
    defer result.deinit();

    // The effective minimum permits one complete page beyond the active page.
    // Fill that allowance so the following allocation exceeds the byte limit.
    {
        var allocation = try TestSupport.allocatePage(&result, .{ .cols = 1, .rows = 1 });
        defer allocation.deinit();
        allocation.page().size.rows = 1;
        try allocation.finalize(.prepend);
    }

    const before_first = result.pages.first.?;
    const before_total_rows = result.total_rows;
    const before_page_size = result.page_size;

    var allocation = try TestSupport.allocatePage(&result, .{ .cols = 1, .rows = 1 });
    defer allocation.deinit();
    allocation.page().size.rows = 1;
    try testing.expectError(
        error.MaxSizeExceeded,
        allocation.finalize(.prepend),
    );

    try testing.expectEqual(before_first, result.pages.first.?);
    try testing.expectEqual(before_total_rows, result.total_rows);
    try testing.expectEqual(before_page_size, result.page_size);
    result.assertIntegrity();
}

test "PageList incremental compression skips visible history" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, 3);

    const initial_activity = s.page_compression.activity_serial;
    try testing.expect(initial_activity > 0);

    s.scroll(.top);
    const top_activity = s.page_compression.activity_serial;
    try testing.expect(top_activity != initial_activity);
    try testing.expectEqual(
        IncrementalCompressionResult.complete,
        s.compress(.drain),
    );

    const first = s.pages.first.?;
    const second = first.next.?;
    try testing.expectEqual(first, s.getTopLeft(.viewport).node);
    try testing.expectEqual(first, s.getBottomRight(.viewport).?.node);
    try testing.expect(!nodeIsCompressed(first));

    var eligible: CompressionIterator = PageList.TestAccess.compressionIterator(&s);
    var compressed_pages: usize = 0;
    while (PageList.TestAccess.nextCompressionPage(&eligible)) |node| {
        compressed_pages += 1;
        try testing.expect(nodeIsCompressed(node));
    }
    try testing.expect(compressed_pages > 0);

    // Move the viewport to the start of the second page. Rendering it restores
    // that page, while the first page which just left view becomes eligible.
    s.scroll(.{ .row = first.rows() });
    try testing.expectEqual(second, s.getTopLeft(.viewport).node);
    _ = second.page();
    try testing.expect(!nodeIsCompressed(second));
    _ = s.compress(.drain);
    try testing.expect(nodeIsCompressed(first));
    try testing.expect(!nodeIsCompressed(second));

    // Returning to the active area makes every complete historical page
    // eligible again, including the page which was just visible.
    s.scroll(.active);
    _ = s.compress(.drain);
    try testing.expect(nodeIsCompressed(second));
    try testing.expect(!s.page_compression.flags.did_compress);
    try testing.expect(!s.page_compression.flags.verifying);
    try testing.expectEqual(@as(?u64, null), s.page_compression.last_serial);
    try testing.expectEqual(@as(u64, 0), s.page_compression.next_serial);
}

test "PageList owns incremental compression state" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    const state: IncrementalCompressionState = .{
        .flags = .{
            .did_compress = true,
            .verifying = true,
        },
        .activity_serial = 42,
        .last_serial = 42,
        .next_serial = 43,
    };

    s.page_compression = state;
    s.scroll(.top);
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 43 },
        s.page_compression,
    );

    // Every scroll restarts traversal, even if clamping leaves the viewport in
    // the same place. Missing an eligible page is worse than a no-op pass.
    s.page_compression = state;
    s.scroll(.top);
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 43 },
        s.page_compression,
    );

    s.page_compression = state;
    s.scroll(.active);
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 43 },
        s.page_compression,
    );

    s.page_compression = state;
    try s.resize(.{ .cols = 80, .rows = 24 });
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 43 },
        s.page_compression,
    );

    s.page_compression = state;
    s.reset();
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 42 },
        s.page_compression,
    );

    s.page_compression = state;
    try testing.expectEqual(
        IncrementalCompressionResult.complete,
        s.compress(.full),
    );
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 42 },
        s.page_compression,
    );

    s.page_compression = state;
    var cloned = try s.clone(testing.allocator, .{
        .top = .{ .active = .{} },
    });
    defer cloned.deinit();
    try testing.expectEqual(
        IncrementalCompressionState{},
        cloned.page_compression,
    );
}

test "PageList replacements preserve compression continuation and mark activity" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    const state: IncrementalCompressionState = .{
        .flags = .{ .verifying = true },
        .activity_serial = 42,
        .last_serial = 7,
        .next_serial = 8,
    };
    const expected: IncrementalCompressionState = .{
        .flags = .{ .verifying = true },
        .activity_serial = 43,
        .last_serial = 7,
        .next_serial = 8,
    };

    s.page_compression = state;
    const replacement = try s.increaseCapacity(s.pages.first.?, null);
    try testing.expectEqual(expected, s.page_compression);

    s.page_compression = state;
    _ = (try s.compact(replacement)).?;
    try testing.expectEqual(expected, s.page_compression);
}

test "PageList incremental compression bounds inspected pages" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, incremental_compression_max_inspected + 1);

    // Precompress every candidate so the incremental pass exercises its
    // metadata-only skip budget without stopping at a resident attempt.
    _ = s.compress(.full);
    PageList.TestAccess.resetCompression(&s.page_compression);
    PageList.TestAccess.compressionActivity(&s.page_compression);
    try testing.expectEqual(
        incremental_compression_max_inspected + 1,
        s.memoryStats().compressed_pages,
    );

    var expected_last = s.pages.first.?;
    for (1..incremental_compression_max_inspected) |_|
        expected_last = expected_last.next.?;

    const first = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, first);
    try testing.expectEqual(
        expected_last.serial,
        s.page_compression.last_serial.?,
    );

    const second = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, second);
    try testing.expect(s.page_compression.flags.verifying);
    try testing.expect(s.page_compression.last_serial == null);

    // The verification pass is bounded independently, too.
    try testing.expectEqual(
        IncrementalCompressionResult.pending,
        s.compress(.incremental),
    );
    try testing.expectEqual(
        IncrementalCompressionResult.complete,
        s.compress(.incremental),
    );
}

test "PageList incremental compression advances after failure" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, 2);

    const first = s.pages.first.?;
    const second = first.next.?;
    var prng = std.Random.DefaultPrng.init(0x494E_4352_5041_5353);
    prng.random().bytes(first.page().memory);

    const failed = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, failed);
    try testing.expect(!nodeIsCompressed(first));

    // The unsuccessful first page does not stall the pass. The next step
    // continues at the following serial and compresses that page.
    const continued = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, continued);
    try testing.expect(nodeIsCompressed(second));
}

test "PageList incremental compression advances after allocation failure" {
    const testing = std.testing;

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, 2);
    const first = s.pages.first.?;
    const second = first.next.?;

    // Pool preheating supplies compression scratch. Failing the allocator's
    // next request therefore rejects the exact encoded allocation while the
    // source page and pass remain valid.
    failing.fail_index = failing.alloc_index;
    const failed = s.compress(.incremental);
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(IncrementalCompressionResult.pending, failed);
    try testing.expect(!nodeIsCompressed(first));

    // Allow allocations again. The pass must continue with the following page
    // rather than retrying the failed candidate.
    failing.fail_index = std.math.maxInt(usize);
    const continued = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, continued);
    try testing.expect(nodeIsCompressed(second));
}

test "PageList incremental compression advances after decommit failure" {
    const testing = std.testing;
    const tw = compressPage_tw;
    defer tw.end(.reset) catch unreachable;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, 2);

    tw.errorAlways(.decommit, error.DecommitFailed);
    const failed = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, failed);
    try testing.expect(!nodeIsCompressed(s.pages.first.?));
    try tw.end(.reset);

    // The failed candidate remains resident and the pass continues at the
    // next serial once reclamation is available again.
    const continued = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, continued);
    try testing.expect(nodeIsCompressed(s.pages.first.?.next.?));
}

test "PageList incremental compression restarts after replacement" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, 1);

    const initial = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, initial);
    try testing.expect(nodeIsCompressed(s.pages.first.?));

    const old = s.pages.first.?;
    const old_serial = old.serial;
    var replacement = old;
    while (replacement.page().memory.len <= std_size) {
        replacement = try s.increaseCapacity(
            replacement,
            .grapheme_bytes,
        );
    }
    try testing.expect(replacement.serial != old_serial);
    try testing.expect(replacement.page().memory.len > std_size);
    try testing.expect(!nodeIsCompressed(replacement));

    // The exact continuation serial disappeared with the old node. The pass
    // restarts at the first page and considers the oversized replacement.
    const restarted = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, restarted);
    try testing.expect(nodeIsCompressed(replacement));
}

test "PageList incremental compression restarts after reset" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, 1);

    const initial = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, initial);
    try testing.expect(nodeIsCompressed(s.pages.first.?));

    // Reset replaces every page and clears the PageList-owned traversal.
    s.reset();
    try growColdPagesForTest(&s, 1);
    const restarted = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, restarted);
    try testing.expect(nodeIsCompressed(s.pages.first.?));
}

test "PageList incremental compression restarts after prune reuse" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 2 * PagePool.item_size,
    });
    defer s.deinit();
    try growColdPagesForTest(&s, 1);

    const initial = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, initial);
    try testing.expect(nodeIsCompressed(s.pages.first.?));

    const reused = s.pages.first.?;
    const old_serial = reused.serial;
    while (s.pages.last.?.rows() < s.pages.last.?.capacity().rows) {
        _ = try s.grow();
    }
    try testing.expectEqual(reused, (try s.grow()).?);
    try testing.expect(reused.serial != old_serial);

    // Make the remaining old page fully historical. The continuation serial
    // disappeared when its node was recycled, so the pass safely restarts.
    try growColdPagesForTest(&s, 1);
    _ = s.compress(.incremental);
    try testing.expectEqual(@as(usize, 1), s.memoryStats().compressed_pages);
}

test "PageList bounded pruning after partial erase preserves live serials" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 2 * PagePool.item_size,
    });
    defer s.deinit();

    while (s.totalPages() < 2) _ = try s.grow();
    const first = s.pages.first.?;
    const old_serial = first.serial;
    const old_rows = first.rows();

    s.eraseHistory(.{ .history = .{ .y = 0 } });
    try testing.expectEqual(first, s.pages.first.?);
    try testing.expectEqual(old_rows - 1, first.rows());
    try testing.expect(!s.nodeIsValid(first, old_serial));

    try fillLastPageForTest(&s);
    _ = try s.grow();
    try expectLivePageSerialsValidForTest(&s);
}

test "PageList partial erase restarts compression before continuation" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, incremental_compression_max_inspected + 1);
    _ = s.compress(.full);

    const first = s.pages.first.?;
    try testing.expect(nodeIsCompressed(first));

    var marker = first;
    for (1..incremental_compression_max_inspected) |_| marker = marker.next.?;
    s.page_compression = .{
        .flags = .{ .verifying = true },
        .last_serial = marker.serial,
        .next_serial = s.page_serial,
    };

    const activity = s.page_compression.activity_serial;
    s.eraseHistory(.{ .history = .{ .y = 0 } });
    try testing.expect(!nodeIsCompressed(first));
    try testing.expect(activity != s.page_compression.activity_serial);

    // The changed generation is before the saved marker, so continuation must
    // restart and recompress it instead of reporting verification complete.
    try testing.expectEqual(
        IncrementalCompressionResult.pending,
        s.compress(.incremental),
    );
    try testing.expect(nodeIsCompressed(first));
}

test "PageList bounded pruning after split invalidation preserves live serials" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 2 * PagePool.item_size,
    });
    defer s.deinit();

    while (s.totalPages() < 2) _ = try s.grow();
    const first = s.pages.first.?;
    const old_serial = first.serial;
    const activity = s.page_compression.activity_serial;

    try s.split(.{
        .node = first,
        .y = first.rows() / 2,
        .x = 0,
    });
    try testing.expect(!s.nodeIsValid(first, old_serial));
    try testing.expect(activity != s.page_compression.activity_serial);

    try fillLastPageForTest(&s);
    _ = try s.grow();
    try expectLivePageSerialsValidForTest(&s);
}

test "PageList repeated bounded pruning after split preserves live serials" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 3 * PagePool.item_size,
    });
    defer s.deinit();

    const epoch = s.page_serial_epoch;
    while (s.totalPages() < 3) _ = try s.grow();
    const first = s.pages.first.?;
    try s.split(.{
        .node = first,
        .y = first.rows() / 2,
        .x = 0,
    });

    // The split target has a fresh serial but precedes older successor pages.
    // Prune both the old source and then that target while verifying ordinary
    // list mutation does not advance the whole-list validity epoch.
    for (0..2) |_| {
        while (s.pages.last.?.rows() < s.pages.last.?.capacity().rows) {
            _ = try s.grow();
        }
        _ = try s.grow();

        // Ordinary pruning invalidates one generation at a time through live
        // list validation; only reset may begin a new whole-list epoch.
        try testing.expectEqual(epoch, s.page_serial_epoch);
        try expectLivePageSerialsValidForTest(&s);
    }
}

test "PageList bounded pruning after front replacement preserves live serials" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 2 * PagePool.item_size,
    });
    defer s.deinit();

    while (s.totalPages() < 2) _ = try s.grow();
    const old = s.pages.first.?;
    const old_serial = old.serial;
    const replacement = try s.increaseCapacity(old, null);
    try testing.expect(replacement != old);
    try testing.expect(!s.nodeIsValid(old, old_serial));

    try fillLastPageForTest(&s);
    _ = try s.grow();

    try expectLivePageSerialsValidForTest(&s);
}

test "PageList bounded pruning after middle replacement preserves live serials" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 3 * PagePool.item_size,
    });
    defer s.deinit();

    while (s.totalPages() < 3) _ = try s.grow();
    const old = s.pages.first.?.next.?;
    const old_serial = old.serial;
    const replacement = try s.increaseCapacity(old, null);
    try testing.expect(replacement != old);
    try testing.expect(!s.nodeIsValid(old, old_serial));

    // Prune the original first page and then the fresh middle replacement.
    for (0..2) |_| {
        try fillLastPageForTest(&s);
        _ = try s.grow();
        try expectLivePageSerialsValidForTest(&s);
    }
}

test "PageList incremental compression restarts after earlier replacement" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, 3);

    _ = s.compress(.incremental);
    _ = s.compress(.incremental);
    try testing.expect(nodeIsCompressed(s.pages.first.?));
    try testing.expect(nodeIsCompressed(s.pages.first.?.next.?));

    // Replace a page before the still-valid continuation marker. The list's
    // allocation serial changes even though the marker itself remains, so the
    // next step must restart and inspect the replacement.
    const old_first = s.pages.first.?;
    const old_serial = old_first.serial;
    const replacement = try s.increaseCapacity(
        old_first,
        .grapheme_bytes,
    );
    try testing.expect(replacement.serial != old_serial);
    try testing.expect(!nodeIsCompressed(replacement));

    _ = s.compress(.incremental);
    try testing.expect(nodeIsCompressed(replacement));
}

test "PageList incremental compression keeps progress after tail growth" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, incremental_compression_max_inspected + 1);
    _ = s.compress(.full);
    PageList.TestAccess.resetCompression(&s.page_compression);
    PageList.TestAccess.compressionActivity(&s.page_compression);

    var expected_last = s.pages.first.?;
    for (1..incremental_compression_max_inspected) |_|
        expected_last = expected_last.next.?;

    const first = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, first);
    try testing.expectEqual(
        expected_last.serial,
        s.page_compression.last_serial.?,
    );

    // Allocate a new page at the active tail between steps. It is after the
    // continuation marker and must not restart progress through cold history.
    const next_serial = s.page_serial;
    while (s.page_serial == next_serial) _ = try s.grow();
    const continued = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, continued);
    try testing.expect(s.page_compression.flags.verifying);
}

test "PageList memory stats do not restore compressed pages" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, 2);

    const before = s.memoryStats();
    try testing.expectEqual(s.totalPages(), before.resident_pages);
    try testing.expectEqual(@as(usize, 0), before.compressed_pages);
    try testing.expectEqual(s.page_size, before.raw_bytes);
    try testing.expectEqual(before.raw_bytes, before.resident_raw_bytes);
    try testing.expectEqual(@as(usize, 0), before.decommitted_raw_bytes);
    try testing.expectEqual(s.page_size, before.resident_backing_bytes);
    try testing.expectEqual(@as(usize, 0), before.encoded_bytes);
    try testing.expectEqual(
        before.resident_backing_bytes,
        before.estimatedResidentBytes(),
    );
    try testing.expectEqual(@as(usize, 0), before.estimatedSavings());

    _ = s.compress(.full);
    const first = s.pages.first.?;
    try testing.expectEqual(Node.Storage.compressed, first.storage());
    try testing.expect(first.pageIfResident() == null);

    const after = s.memoryStats();
    try testing.expect(nodeIsCompressed(first));
    try testing.expectEqual(s.totalPages(), after.resident_pages + after.compressed_pages);
    try testing.expectEqual(@as(usize, 2), after.compressed_pages);
    try testing.expectEqual(s.page_size, after.raw_bytes);
    try testing.expectEqual(
        after.raw_bytes,
        after.resident_raw_bytes + after.decommitted_raw_bytes,
    );
    try testing.expectEqual(
        after.resident_backing_bytes + after.encoded_bytes,
        after.estimatedResidentBytes(),
    );
    try testing.expectEqual(
        after.decommitted_raw_bytes - after.encoded_bytes,
        after.estimatedSavings(),
    );

    const first_raw_len = nodeMetadata(first).memory.len;
    const first_encoded_len = first.data.compressed.encoded.len;
    _ = first.page();
    try testing.expectEqual(Node.Storage.resident, first.storage());
    try testing.expect(first.pageIfResident() != null);

    const restored = s.memoryStats();
    try testing.expectEqual(after.resident_pages + 1, restored.resident_pages);
    try testing.expectEqual(after.compressed_pages - 1, restored.compressed_pages);
    try testing.expectEqual(after.raw_bytes, restored.raw_bytes);
    try testing.expectEqual(
        after.resident_raw_bytes + first_raw_len,
        restored.resident_raw_bytes,
    );
    try testing.expectEqual(
        after.decommitted_raw_bytes - first_raw_len,
        restored.decommitted_raw_bytes,
    );
    try testing.expectEqual(
        after.resident_backing_bytes + first_raw_len,
        restored.resident_backing_bytes,
    );
    try testing.expectEqual(
        after.encoded_bytes - first_encoded_len,
        restored.encoded_bytes,
    );
}

test "PageList preserved page keeps compressed storage" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    const node = s.pages.first.?;
    const resident = node.page();
    resident.dirty = true;
    resident.getRowAndCell(3, 2).cell.* = .init('X');

    // Resident nodes can be borrowed without allocating an unnecessary copy.
    {
        var failing = testing.FailingAllocator.init(alloc, .{
            .fail_index = 0,
        });
        var preserved = try node.pagePreservingState(failing.allocator());
        defer preserved.deinit();
        switch (preserved) {
            .borrowed => |page_| try testing.expectEqual(resident, page_),
            .owned => try testing.expect(false),
        }
        try testing.expect(!failing.has_induced_failure);
    }

    const expected = try alloc.dupe(u8, resident.memory);
    defer alloc.free(expected);
    const retained_ptr = resident.memory.ptr;

    try testing.expect(compressPage(&s, node));
    const stats = s.memoryStats();
    const expected_encoded = try alloc.dupe(u8, node.data.compressed.encoded);
    defer alloc.free(expected_encoded);

    // Test decommit simulates physical reclamation by clearing the retained
    // mapping. A preserved page must decode elsewhere rather than restoring
    // it.
    try testing.expect(std.mem.allEqual(u8, nodeMetadata(node).memory, 0));

    // Preserved-page allocation is opportunistic for callers. Failure leaves
    // the node and its compressed representation untouched.
    var failing = testing.FailingAllocator.init(alloc, .{
        .fail_index = 0,
    });
    try testing.expectError(
        error.OutOfMemory,
        node.pagePreservingState(failing.allocator()),
    );
    try testing.expectEqual(Node.Storage.compressed, node.storage());
    try testing.expectEqual(stats, s.memoryStats());

    var preserved = try node.pagePreservingState(alloc);
    defer preserved.deinit();
    switch (preserved) {
        .borrowed => try testing.expect(false),
        .owned => {},
    }
    const page_ = preserved.page();

    try testing.expect(page_.memory.ptr != retained_ptr);
    try testing.expectEqualSlices(u8, expected, page_.memory);
    try testing.expect(page_.dirty);
    try testing.expectEqual(
        @as(u21, 'X'),
        page_.getRowAndCell(3, 2).cell.content.codepoint.data,
    );

    // The node still owns the same compressed representation, and neither its
    // storage accounting nor its discarded raw mapping changed while cloning.
    try testing.expectEqual(Node.Storage.compressed, node.storage());
    try testing.expectEqual(stats, s.memoryStats());
    try testing.expectEqual(retained_ptr, nodeMetadata(node).memory.ptr);
    try testing.expect(std.mem.allEqual(u8, nodeMetadata(node).memory, 0));
    try testing.expectEqualSlices(
        u8,
        expected_encoded,
        node.data.compressed.encoded,
    );
}

test "PageList memory stats include unused pool backing" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Pool allocation ownership is based on the requested layout fitting in a
    // standard item. The Page itself exposes only the initialized prefix.
    const node = try createPage(&s, .{ .cap = .{ .cols = 1, .rows = 1 } });
    try testing.expectEqual(PageList.TestAccess.PageOwnership.pool, node.owned);
    try testing.expect(node.page().memory.len < PagePool.item_size);
    node.page().size.rows = 1;
    s.pages.append(node);
    s.total_rows += 1;

    const raw_len = nodeMetadata(node).memory.len;
    const before = s.memoryStats();
    try testing.expect(before.raw_bytes < s.page_size);
    try testing.expectEqual(before.raw_bytes, before.resident_raw_bytes);
    try testing.expectEqual(s.page_size, before.resident_backing_bytes);
    try testing.expectEqual(s.page_size, before.estimatedResidentBytes());

    try testing.expect(compressPage(&s, node));
    const encoded_len = node.data.compressed.encoded.len;
    const compressed = s.memoryStats();
    try testing.expectEqual(before.raw_bytes, compressed.raw_bytes);
    try testing.expectEqual(
        before.resident_raw_bytes - raw_len,
        compressed.resident_raw_bytes,
    );
    try testing.expectEqual(raw_len, compressed.decommitted_raw_bytes);
    try testing.expectEqual(
        before.resident_backing_bytes - raw_len,
        compressed.resident_backing_bytes,
    );
    try testing.expectEqual(encoded_len, compressed.encoded_bytes);
    try testing.expectEqual(
        before.estimatedResidentBytes() - raw_len + encoded_len,
        compressed.estimatedResidentBytes(),
    );
}

test "PageList does not compress the mixed history and active page" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // One additional row creates history, but the history and all active rows
    // still share the first page. The active boundary therefore has a
    // historical prefix and must remain resident as one indivisible mapping.
    _ = try s.grow();
    const active = s.getTopLeft(.active);
    try testing.expectEqual(s.pages.first.?, active.node);
    try testing.expect(active.y > 0);

    _ = s.compress(.full);
    try testing.expect(!nodeIsCompressed(s.pages.first.?));
}

test "PageList compresses only complete cold history pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // More active rows than one page at these dimensions can hold ensures the
    // active area spans multiple nodes when the pass chooses its boundary.
    const active_rows = initialCapacity(80).rows + 1;
    var s = try init(alloc, .{ .cols = 80, .rows = active_rows });
    defer s.deinit();
    try growColdPagesForTest(&s, 2);

    // Move the active top into the boundary page so it has both a historical
    // prefix and active rows while the active area still spans later pages.
    _ = try s.grow();

    const active = s.getTopLeft(.active);
    const active_node = active.node;
    try testing.expect(active.y > 0);
    try testing.expect(active_node != s.pages.last.?);

    var expected_compressed: usize = 0;
    var expected_raw_bytes: usize = 0;
    var current = s.pages.first;
    while (current) |node| : (current = node.next) {
        if (node == active_node) break;
        expected_compressed += 1;
        expected_raw_bytes += nodeMetadata(node).memory.len;
    }
    try testing.expectEqual(@as(usize, 2), expected_compressed);

    const first = s.pages.first.?;
    first.page().getRowAndCell(0, 0).cell.* = .init('X');
    const expected = try alloc.dupe(u8, first.page().memory);
    defer alloc.free(expected);
    const first_memory = first.page().memory.ptr;
    const page_size = s.page_size;

    _ = s.compress(.full);
    const memory = s.memoryStats();
    try testing.expectEqual(expected_compressed, memory.compressed_pages);
    try testing.expectEqual(expected_raw_bytes, memory.decommitted_raw_bytes);
    try testing.expect(memory.encoded_bytes < memory.decommitted_raw_bytes);
    try testing.expectEqual(page_size, s.page_size);

    current = s.pages.first;
    var actual_encoded_bytes: usize = 0;
    while (current) |node| : (current = node.next) {
        if (node == active_node) break;
        try testing.expect(nodeIsCompressed(node));
        actual_encoded_bytes += node.data.compressed.encoded.len;
    }
    try testing.expectEqual(actual_encoded_bytes, memory.encoded_bytes);
    current = active_node;
    while (current) |node| : (current = node.next) {
        try testing.expect(!nodeIsCompressed(node));
    }

    // Restoring the oldest page preserves both the mapping identity and all
    // of its bytes even though the pass discarded its physical pages.
    try testing.expectEqual(first_memory, nodeMetadata(first).memory.ptr);
    try testing.expectEqualSlices(u8, expected, first.page().memory);
    try testing.expectEqual(first_memory, first.page().memory.ptr);
}

test "PageList cold compression continues after an incompressible page" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try growColdPagesForTest(&s, 2);

    const first = s.pages.first.?;
    const second = first.next.?;
    var prng = std.Random.DefaultPrng.init(0x434F_4C44_5041_4745);
    prng.random().bytes(first.page().memory);

    const page_size = s.page_size;
    _ = s.compress(.full);
    const memory = s.memoryStats();
    try testing.expectEqual(@as(usize, 1), memory.compressed_pages);
    try testing.expect(!nodeIsCompressed(first));
    try testing.expect(nodeIsCompressed(second));
    try testing.expectEqual(
        nodeMetadata(second).memory.len,
        memory.decommitted_raw_bytes,
    );
    try testing.expect(memory.encoded_bytes < memory.decommitted_raw_bytes);
    try testing.expectEqual(page_size, s.page_size);

    // Failed resident candidates are deliberately retried on later passes,
    // while the successful page remains compressed and is skipped.
    _ = s.compress(.full);
    try testing.expectEqual(memory, s.memoryStats());
}

test "PageList compression restores through page access" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    const node = s.pages.first.?;
    const page = node.page();
    page.dirty = true;
    page.getRowAndCell(3, 2).cell.* = .init('X');

    const expected = try alloc.dupe(u8, page.memory);
    defer alloc.free(expected);
    const memory_ptr = page.memory.ptr;
    const memory_len = page.memory.len;
    const page_size = s.page_size;

    try testing.expect(compressPage(&s, node));
    try testing.expect(nodeIsCompressed(node));
    try testing.expectEqual(@as(size.CellCountInt, 24), node.rows());
    try testing.expectEqual(@as(size.CellCountInt, 80), node.cols());
    try testing.expectEqual(memory_ptr, nodeMetadata(node).memory.ptr);
    try testing.expectEqual(memory_len, nodeMetadata(node).memory.len);
    try testing.expectEqual(page_size, s.page_size);

    // Pin access restores the page without changing its retained mapping.
    const page_pin: Pin = .{ .node = node, .x = 3, .y = 2 };
    try testing.expectEqual(
        @as(u21, 'X'),
        page_pin.rowAndCell().cell.content.codepoint.data,
    );
    try testing.expect(!nodeIsCompressed(node));
    try testing.expectEqual(memory_ptr, node.page().memory.ptr);
    try testing.expectEqualSlices(u8, expected, node.page().memory);
    try testing.expect(node.page().dirty);

    // Recompressing exercises reuse of the page-pool scratch item. Page
    // iterator chunks also restore before exposing row memory.
    try testing.expect(compressPage(&s, node));
    var page_it = (Pin{ .node = node }).pageIterator(.right_down, null);
    const chunk = page_it.next().?;
    try testing.expectEqual(node.rows(), chunk.rows().len);
    try testing.expect(!nodeIsCompressed(node));
    try testing.expectEqualSlices(u8, expected, node.page().memory);

    // Read-only PageList operations restore through the same boundary.
    try testing.expect(compressPage(&s, node));
    var cloned = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
    });
    defer cloned.deinit();
    try testing.expect(!nodeIsCompressed(node));
    try testing.expectEqual(
        @as(u21, 'X'),
        cloned.pages.first.?.page().getRowAndCell(3, 2).cell.content.codepoint.data,
    );
}

test "PageList compression uses temporary scratch for oversized pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    var node = s.pages.first.?;
    while (node.page().memory.len <= std_size) {
        node = try s.increaseCapacity(node, .grapheme_bytes);
    }

    const expected = try alloc.dupe(u8, node.page().memory);
    defer alloc.free(expected);
    const memory_ptr = node.page().memory.ptr;
    const memory_len = node.page().memory.len;
    const page_size = s.page_size;

    try testing.expect(compressPage(&s, node));
    try testing.expect(nodeIsCompressed(node));
    try testing.expectEqual(page_size, s.page_size);
    try testing.expectEqual(memory_ptr, nodeMetadata(node).memory.ptr);
    try testing.expectEqual(memory_len, nodeMetadata(node).memory.len);

    try testing.expectEqualSlices(u8, expected, node.page().memory);
    try testing.expect(!nodeIsCompressed(node));
    try testing.expectEqual(memory_ptr, node.page().memory.ptr);
}

test "PageList compression leaves incompressible pages resident" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    const node = s.pages.first.?;
    const original = try alloc.dupe(u8, node.page().memory);
    defer alloc.free(original);
    defer @memcpy(node.page().memory, original);

    var prng = std.Random.DefaultPrng.init(0x5041_4745_4C49_5354);
    prng.random().bytes(node.page().memory);
    const page_size = s.page_size;

    try testing.expect(!compressPage(&s, node));
    try testing.expect(!nodeIsCompressed(node));
    try testing.expectEqual(page_size, s.page_size);
}

test "PageList reset discards malformed compressed data" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    const node = s.pages.first.?;
    try testing.expect(compressPage(&s, node));
    @memset(node.data.compressed.encoded, 0xFF);

    s.reset();
    try testing.expect(!nodeIsCompressed(s.pages.first.?));
    try testing.expectEqual(@as(usize, 1), s.totalPages());
}

test "PageList deinit discards malformed compressed data" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    const node = s.pages.first.?;
    try testing.expect(compressPage(&s, node));
    @memset(node.data.compressed.encoded, 0xFF);

    s.deinit();
}

test "PageList prune reuses malformed compressed page memory" {
    const testing = std.testing;

    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 2 * PagePool.item_size,
    });
    defer s.deinit();

    // Allocate the second page so the first one can be pruned and reused.
    while (s.pages.first == s.pages.last) _ = try s.grow();
    const first = s.pages.first.?;
    try testing.expect(compressPage(&s, first));
    @memset(first.data.compressed.encoded, 0xFF);

    var reused = false;
    const growth_limit = @as(usize, s.pages.last.?.capacity().rows) + 1;
    for (0..growth_limit) |_| {
        if (try s.grow()) |new_node| {
            if (new_node == first) {
                reused = true;
                break;
            }
        }
    }

    try testing.expect(reused);
    try testing.expectEqual(first, s.pages.last.?);
    try testing.expect(!nodeIsCompressed(first));
    try testing.expectEqual(@as(size.CellCountInt, 1), first.rows());
    first.page().assertIntegrity();
}

test "PageList active after grow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));

    try growRows(&s, 10);
    try testing.expectEqual(@as(usize, s.rows + 10), totalRows(&s));

    // Make sure all points make sense
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
    {
        const pt = s.getCell(.{ .screen = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    // Scrollbar should be in the active area
    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = 10,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList grow allows exceeding max size for active area" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Setup our initial page so that we fully take up one page.
    const cap = try std_capacity.adjust(.{ .cols = 5 });
    var s = try init(alloc, .{ .cols = 5, .rows = cap.rows, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), totalRows(&s));

    // Grow once because we guarantee at least two pages of
    // capacity so we want to get to that.
    _ = try s.grow();
    const start_pages = s.totalPages();
    try testing.expect(start_pages >= 2);

    // Surgically modify our pages so that they have a smaller size.
    {
        var it = s.pages.first;
        while (it) |page| : (it = page.next) {
            page.page().size.rows = 1;
            page.page().capacity.rows = 1;
        }

        // Avoid integrity check failures
        s.total_rows = totalRows(&s);
    }

    // Grow our row and ensure we don't prune pages because we need
    // enough for the active area.
    _ = try s.grow();
    try testing.expectEqual(start_pages + 1, s.totalPages());
}

test "PageList grow prune required with a single page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Need scrollback > 0 to have a scrollbar to test
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // This block is all test setup. There is nothing required about this
    // behavior during a refactor. This is setting up a scenario that is
    // possible to trigger a bug (#2280).
    {
        // Increase our capacity until our page is larger than the standard size.
        // This is important because it triggers a scenario where our calculated
        // minSize() which is supposed to accommodate 2 pages is no longer true.
        while (true) {
            const layout = Page.layout(s.pages.first.?.capacity());
            if (layout.total_size > std_size) break;
            _ = try s.increaseCapacity(s.pages.first.?, .grapheme_bytes);
        }
        try testing.expect(s.pages.first != null);
        try testing.expect(s.pages.first == s.pages.last);
    }

    // Figure out the remaining number of rows. This is the amount that
    // can be added to the current page before we need to allocate a new
    // page.
    const rem = rem: {
        const page = s.pages.first.?;
        break :rem page.capacity().rows - page.rows();
    };
    for (0..rem) |_| try testing.expect(try s.grow() == null);

    // The next one we add will trigger a new page.
    const new = try s.grow();
    try testing.expect(new != null);
    try testing.expect(new != s.pages.first);

    // Scrollbar should be in the active area
    try testing.expectEqual(Scrollbar{
        .total = totalRows(&s),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList grow allocate" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Grow to capacity
    const last_node = s.pages.last.?;
    const last = s.pages.last.?.page();
    for (0..last.capacity.rows - last.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }

    // Grow, should allocate
    const new = (try s.grow()).?;
    try testing.expect(s.pages.last.? == new);
    try testing.expect(last_node.next.? == new);
    {
        const cell = s.getCell(.{ .active = .{ .y = s.rows - 1 } }).?;
        try testing.expect(cell.node == new);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = last.capacity.rows,
        } }, cell.screenPoint());
    }
}

test "PageList set max bytes prunes immediately and can be raised" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;

    var s = try init(testing.allocator, .{
        .cols = cols,
        .rows = 1,
        .max_size = null,
    });
    defer s.deinit();

    // Build four complete pages of history followed by the active row.
    try growRows(&s, 4 * page_rows);
    try testing.expectEqual(@as(usize, 5), s.totalPages());

    const removed = s.pages.first.?;
    const retained = s.pages.last.?.prev.?;
    const removed_pin = try s.trackPin(.{ .node = removed });
    defer s.untrackPin(removed_pin);
    const retained_pin = try s.trackPin(.{ .node = retained });
    defer s.untrackPin(retained_pin);

    s.scroll(.{ .pin = retained_pin.* });
    try testing.expectEqual(3 * page_rows, s.scrollbar().offset);

    // The active-area minimum is two pages. Lowering below that immediately
    // removes all older complete historical pages.
    s.setMaxBytes(PagePool.item_size);
    try testing.expectEqual(PagePool.item_size, s.limits.bytes.explicit);
    try testing.expectEqual(2 * PagePool.item_size, s.limits.max(.bytes));
    try testing.expectEqual(s.limits.max(.bytes), s.page_size);
    try testing.expectEqual(@as(usize, 2), s.totalPages());
    try testing.expectEqual(page_rows, s.total_rows - s.rows);
    try testing.expectEqual(retained, s.pages.first.?);
    try testing.expectEqual(retained, removed_pin.node);
    try testing.expect(removed_pin.garbage);
    try testing.expectEqual(retained, retained_pin.node);
    try testing.expect(!retained_pin.garbage);
    try testing.expectEqual(@as(usize, 0), s.scrollbar().offset);

    // Raising the limit doesn't allocate or otherwise change retained data,
    // but subsequent growth can exceed the previous effective limit.
    const limited_size = s.page_size;
    const limited_rows = s.total_rows;
    s.setMaxBytes(8 * PagePool.item_size);
    try testing.expectEqual(limited_size, s.page_size);
    try testing.expectEqual(limited_rows, s.total_rows);
    try growRows(&s, 2 * page_rows);
    try testing.expect(s.page_size > limited_size);

    // Null restores unlimited growth and likewise preserves current data.
    const raised_size = s.page_size;
    const raised_rows = s.total_rows;
    s.setMaxBytes(null);
    try testing.expectEqual(
        std.math.maxInt(usize),
        s.limits.bytes.explicit,
    );
    try testing.expectEqual(raised_size, s.page_size);
    try testing.expectEqual(raised_rows, s.total_rows);
    try growRows(&s, 5 * page_rows);
    try testing.expect(s.page_size > 8 * PagePool.item_size);
}

test "PageList set max lines prunes immediately and can be raised" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;
    const lowered_lines = page_rows + page_rows / 2;

    var s = try init(testing.allocator, .{
        .cols = cols,
        .rows = 1,
        .max_size = null,
        .max_lines = null,
    });
    defer s.deinit();

    try growRows(&s, 4 * page_rows);
    try testing.expectEqual(@as(usize, 5), s.totalPages());

    const removed = s.pages.first.?;
    const retained = s.pages.last.?.prev.?;
    const removed_pin = try s.trackPin(.{ .node = removed });
    defer s.untrackPin(removed_pin);
    const retained_pin = try s.trackPin(.{ .node = retained });
    defer s.untrackPin(retained_pin);

    s.scroll(.{ .pin = retained_pin.* });
    try testing.expectEqual(3 * page_rows, s.scrollbar().offset);

    // Whole-page enforcement undershoots a non-page-aligned line limit.
    s.setMaxLines(lowered_lines);
    try testing.expectEqual(lowered_lines, s.limits.lines.explicit);
    try testing.expectEqual(lowered_lines, s.limits.max(.lines));
    try testing.expectEqual(page_rows, s.total_rows - s.rows);
    try testing.expectEqual(@as(usize, 2), s.totalPages());
    try testing.expectEqual(retained, s.pages.first.?);
    try testing.expectEqual(retained, removed_pin.node);
    try testing.expect(removed_pin.garbage);
    try testing.expectEqual(retained, retained_pin.node);
    try testing.expect(!retained_pin.garbage);
    try testing.expectEqual(@as(usize, 0), s.scrollbar().offset);

    const limited_size = s.page_size;
    const limited_rows = s.total_rows;
    s.setMaxLines(4 * page_rows);
    try testing.expectEqual(limited_size, s.page_size);
    try testing.expectEqual(limited_rows, s.total_rows);
    try growRows(&s, 2 * page_rows);
    try testing.expect(s.total_rows - s.rows > lowered_lines);

    const raised_size = s.page_size;
    const raised_rows = s.total_rows;
    s.setMaxLines(null);
    try testing.expectEqual(
        std.math.maxInt(usize),
        s.limits.lines.explicit,
    );
    try testing.expectEqual(raised_size, s.page_size);
    try testing.expectEqual(raised_rows, s.total_rows);
    try growRows(&s, 3 * page_rows);
    try testing.expect(s.total_rows - s.rows > 4 * page_rows);
}

test "PageList set max limits remain independent" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;
    const byte_limit = 3 * PagePool.item_size;
    const line_limit = page_rows / 2;

    var s = try init(testing.allocator, .{
        .cols = cols,
        .rows = 1,
        .max_size = null,
        .max_lines = null,
    });
    defer s.deinit();

    try growRows(&s, 4 * page_rows);

    // The byte setter leaves the line limit unlimited.
    s.setMaxBytes(byte_limit);
    try testing.expectEqual(byte_limit, s.limits.bytes.explicit);
    try testing.expectEqual(
        std.math.maxInt(usize),
        s.limits.lines.explicit,
    );
    try testing.expectEqual(@as(usize, 3), s.totalPages());
    try testing.expectEqual(2 * page_rows, s.total_rows - s.rows);

    // The smaller runtime line limit prunes one more complete page without
    // changing the configured byte limit. Its effective value is raised to
    // the existing one-page minimum.
    s.setMaxLines(line_limit);
    try testing.expectEqual(byte_limit, s.limits.bytes.explicit);
    try testing.expectEqual(line_limit, s.limits.lines.explicit);
    try testing.expectEqual(page_rows, s.limits.max(.lines));
    try testing.expectEqual(@as(usize, 2), s.totalPages());
    try testing.expectEqual(page_rows, s.total_rows - s.rows);

    // Removing only the line limit leaves byte enforcement in effect.
    s.setMaxLines(null);
    try growRows(&s, 3 * page_rows);
    try testing.expectEqual(byte_limit, s.page_size);
    try testing.expectEqual(@as(usize, 3), s.totalPages());
    try testing.expect(s.total_rows - s.rows > page_rows);
}

test "PageList max lines does not round larger limits" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;
    const max_lines = page_rows + page_rows / 2;

    var s = try init(testing.allocator, .{
        .cols = cols,
        .rows = 1,
        .max_lines = max_lines,
    });
    defer s.deinit();

    try testing.expectEqual(max_lines, s.limits.max(.lines));
    try growRows(&s, max_lines);
    try testing.expectEqual(max_lines, s.total_rows - s.rows);

    const first = s.pages.first.?;
    const retained = first.next.?;
    const removed_pin = try s.trackPin(.{ .node = first });
    defer s.untrackPin(removed_pin);
    const retained_pin = try s.trackPin(.{ .node = retained });
    defer s.untrackPin(retained_pin);

    s.scroll(.{ .pin = retained_pin.* });
    try testing.expectEqual(page_rows, s.scrollbar().offset);

    const old_page_size = s.page_size;
    _ = try s.grow();

    // Whole-page pruning undershoots the requested limit without rounding it.
    try testing.expectEqual(
        max_lines + 1 - page_rows,
        s.total_rows - s.rows,
    );
    try testing.expectEqual(retained, s.pages.first.?);
    try testing.expectEqual(retained, removed_pin.node);
    try testing.expect(removed_pin.garbage);
    try testing.expectEqual(retained, retained_pin.node);
    try testing.expect(!retained_pin.garbage);
    try testing.expectEqual(@as(usize, 0), s.scrollbar().offset);
    try testing.expectEqual(
        old_page_size - PagePool.item_size,
        s.page_size,
    );
}

test "PageList max lines and max size enforce the smaller limit" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;

    // A line limit of one page keeps the logical allocation below a much
    // larger byte limit.
    {
        var s = try init(testing.allocator, .{
            .cols = cols,
            .rows = 1,
            .max_size = 8 * PagePool.item_size,
            .max_lines = page_rows,
        });
        defer s.deinit();

        try growRows(&s, 4 * page_rows);
        try testing.expect(
            s.total_rows - s.rows <= s.limits.max(.lines),
        );
        try testing.expect(s.totalPages() <= 2);
        try testing.expect(s.page_size < s.limits.max(.bytes));
    }

    // A two-page byte limit prunes before the larger line limit is reached.
    {
        var s = try init(testing.allocator, .{
            .cols = cols,
            .rows = 1,
            .max_size = PagePool.item_size,
            .max_lines = 4 * page_rows,
        });
        defer s.deinit();

        try growRows(&s, 2 * page_rows);
        try testing.expect(
            s.total_rows - s.rows < s.limits.max(.lines),
        );
        try testing.expectEqual(s.limits.max(.bytes), s.page_size);
    }
}

test "PageList promptIterator right_down limit inclusive" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Iterate with limit at row 5 (the prompt row) - should include it
    var it = s.promptIterator(.right_down, .{ .screen = .{} }, .{ .screen = .{ .y = 5 } });
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList promptIterator left_up limit inclusive" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 2, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Iterate with limit at row 10 (the prompt row) - should include it
    // tl_pt is the limit (upper bound), bl_pt is the start point for left_up
    var it = s.promptIterator(.left_up, .{ .screen = .{ .y = 10 } }, .{ .screen = .{ .y = 15 } });
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList erase active regrows automatically" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expect(totalRows(&s) == s.rows);
    s.eraseActive(10);
    try testing.expect(totalRows(&s) == s.rows);
}

test "PageList grow reuses non-standard page without leak" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Create a PageList with 3 * std_size max so we can fit multiple pages
    // but will still trigger reuse.
    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 3 * std_size });
    defer s.deinit();

    // Increase the first page capacity to make it non-standard (larger than std_size).
    while (s.pages.first.?.page().memory.len <= std_size) {
        _ = try s.increaseCapacity(s.pages.first.?, .grapheme_bytes);
    }

    // The first page should now have non-standard memory size.
    try testing.expect(s.pages.first.?.page().memory.len > std_size);

    // First, fill up the first page's capacity
    const first_page = s.pages.first.?;
    while (first_page.rows() < first_page.capacity().rows) {
        _ = try s.grow();
    }

    // Now grow to create a second page
    _ = try s.grow();
    try testing.expect(s.pages.first != s.pages.last);

    // Continue growing until we exceed max_size AND the last page is full
    while (s.page_size + PagePool.item_size <= s.limits.max(.bytes) or
        s.pages.last.?.rows() < s.pages.last.?.capacity().rows)
    {
        _ = try s.grow();
    }

    // The first page should still be non-standard
    try testing.expect(s.pages.first.?.page().memory.len > std_size);

    // Verify we have enough rows for active area (so prune path isn't skipped)
    try testing.expect(totalRows(&s) >= s.rows);

    // Verify last page is full (so grow will need to allocate/reuse)
    try testing.expect(s.pages.last.?.page().size.rows == s.pages.last.?.capacity().rows);

    // Remember the first page memory pointer before the reuse attempt
    const first_page_ptr = s.pages.first.?;
    const first_page_mem_ptr = s.pages.first.?.page().memory.ptr;

    // Create a tracked pin pointing to the non-standard first page
    const tracked_pin = try s.trackPin(.{ .node = first_page_ptr, .x = 0, .y = 0 });
    defer s.untrackPin(tracked_pin);

    // Now grow one more time to trigger the reuse path. Since the first page
    // is non-standard, it should be destroyed (not reused). The testing
    // allocator will detect a leak if destroyNode doesn't properly free
    // the non-standard memory.
    _ = try s.grow();

    // After grow, check if the first page is a different one
    // (meaning the non-standard page was pruned, not reused at the end)
    // The original first page should no longer be the first page
    try testing.expect(s.pages.first.? != first_page_ptr);

    // If the non-standard page was properly destroyed and not reused,
    // the last page should not have the same memory pointer
    try testing.expect(s.pages.last.?.page().memory.ptr != first_page_mem_ptr);

    // The tracked pin should have been moved to the new first page and marked as garbage
    try testing.expectEqual(s.pages.first.?, tracked_pin.node);
    try testing.expectEqual(0, tracked_pin.x);
    try testing.expectEqual(0, tracked_pin.y);
    try testing.expect(tracked_pin.garbage);
}

test "PageList grow non-standard page prune protection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // This test specifically verifies the fix for the bug where pruning a
    // non-standard page would cause totalRows() < self.rows.
    //
    // Bug trigger conditions (all must be true simultaneously):
    // 1. first page is non-standard (memory.len > std_size)
    // 2. page_size + PagePool.item_size > maxSize() (triggers prune consideration)
    // 3. pages.first != pages.last (have multiple pages)
    // 4. total_rows >= self.rows (have enough rows for active area)
    // 5. total_rows - first.size.rows + 1 < self.rows (prune would lose too many)

    // This is kind of magic and likely depends on std_size.
    const rows_count = 600;
    var s = try init(alloc, .{ .cols = 80, .rows = rows_count, .max_size = std_size });
    defer s.deinit();

    // Make the first page non-standard
    while (s.pages.first.?.page().memory.len <= std_size) {
        _ = try s.increaseCapacity(
            s.pages.first.?,
            .grapheme_bytes,
        );
    }
    try testing.expect(s.pages.first.?.page().memory.len > std_size);

    const first_page_node = s.pages.first.?;
    const first_page_cap = first_page_node.capacity().rows;

    // Fill first page to capacity
    while (first_page_node.rows() < first_page_cap) _ = try s.grow();

    // Grow until we have a second page (first page fills up first)
    var second_node: ?*List.Node = null;
    while (s.pages.first == s.pages.last) second_node = try s.grow();
    try testing.expect(s.pages.first != s.pages.last);

    // Fill the second page to capacity so that the next grow() triggers prune
    const last_node = s.pages.last.?;
    const second_cap = last_node.capacity().rows;
    while (last_node.rows() < second_cap) _ = try s.grow();

    // Now the last page is full. The next grow must either:
    // 1. Prune the first page and reuse it, OR
    // 2. Allocate a new page
    const total = totalRows(&s);
    const would_remain = total - first_page_cap + 1;

    // Verify the bug condition is present: pruning first page would leave < rows
    try testing.expect(would_remain < s.rows);

    // Verify prune path conditions are met
    try testing.expect(s.pages.first != s.pages.last);
    try testing.expect(
        s.page_size + PagePool.item_size > s.limits.max(.bytes),
    );
    try testing.expect(totalRows(&s) >= s.rows);

    // Verify last page is at capacity (so grow must prune or allocate new)
    try testing.expectEqual(second_cap, last_node.rows());

    // The next grow should trigger prune consideration.
    // Without the fix, this would destroy the non-standard first page,
    // leaving only second_cap + 1 rows, which is < self.rows.
    _ = try s.grow();

    // Verify the invariant holds - the fix prevents the destructive prune
    try testing.expect(totalRows(&s) >= s.rows);
}

test "PageList compact pool page produces exact-size heap page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();

    // A freshly created page is pool-owned at std_size.
    const node = s.pages.first.?;
    try testing.expectEqual(.pool, node.owned);
    try testing.expect(node.page().memory.len <= std_size);
    const original_size = node.page().size;

    // Compacting it should produce a much smaller exact-size heap page.
    const new_node = (try s.compact(node)).?;
    try testing.expectEqual(.heap, new_node.owned);
    try testing.expect(new_node.page().memory.len < std_size);
    try testing.expectEqual(original_size.rows, new_node.rows());
    try testing.expectEqual(original_size.cols, new_node.cols());
    try testing.expectEqual(new_node, s.pages.first.?);

    // Our page size accounting should exactly match the compacted
    // page since it is the only page in the list.
    try testing.expectEqual(new_node.page().memory.len, s.page_size);

    // Compacting again should be a no-op since it is already exact.
    try testing.expectEqual(null, try s.compact(new_node));
}

test "PageList compact then grow allocates new page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Compact the only page. It now has no spare row capacity.
    const node = (try s.compact(s.pages.first.?)).?;
    try testing.expectEqual(node.rows(), node.capacity().rows);

    // Growing must allocate a fresh standard page from the pool,
    // exercising that a compacted page remains a valid live page.
    _ = try s.grow();
    try testing.expect(s.pages.first != s.pages.last);
    try testing.expectEqual(.pool, s.pages.last.?.owned);
    try testing.expectEqual(@as(usize, 25), totalRows(&s));
}

test "PageList destroyed pool page reuse is zeroed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();

    // Create a page and scribble over its entire backing memory,
    // then destroy it so the buffer returns to the pool free list.
    const node = try createPage(&s, .{ .cap = initialCapacity(80) });
    node.page().size.rows = 1;
    const mem_ptr = node.page().memory.ptr;
    @memset(node.page().memory, 0xAA);
    destroyNode(&s, node);

    // Reusing the buffer must produce a fully valid, zeroed page.
    const node2 = try createPage(&s, .{ .cap = initialCapacity(80) });
    try testing.expectEqual(mem_ptr, node2.page().memory.ptr);
    node2.page().size.rows = node2.capacity().rows;

    const cells_len = @as(usize, node2.capacity().cols) *
        @as(usize, node2.capacity().rows);
    const cells = node2.page().cells.ptr(node2.page().memory)[0..cells_len];
    try testing.expect(std.mem.allEqual(
        u64,
        @as([]const u64, @ptrCast(cells)),
        0,
    ));
    node2.page().assertIntegrity();
    destroyNode(&s, node2);
}

test "PageList eraseActive regrown rows have default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer s.deinit();

    // Mark the rows that will be erased. eraseActive retires their
    // storage into unused page capacity and then regrows the active
    // area, re-exposing the same Row storage via the grow() fast path.
    for (0..2) |y| {
        const rac = s.getCell(.{ .active = .{ .y = @intCast(y) } }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }

    s.eraseActive(1);

    for (0..3) |y| {
        const rac = s.getCell(.{ .active = .{ .y = @intCast(y) } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}

test "PageList memory pool never touches idle page memory" {
    const testing = std.testing;
    const preheat = page_preheat;

    // Back the page allocator with memory we can inspect.
    const backing = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        preheat * std_size,
    );
    defer testing.allocator.free(backing);
    var fba: std.heap.FixedBufferAllocator = .init(backing);

    var pool: MemoryPool = try .init(testing.allocator, fba.allocator(), preheat);
    defer pool.deinit();

    // Preheat allocated exactly the items.
    try testing.expectEqual(preheat * std_size, fba.end_index);

    // Lay the sentinel down after preheat: allocation itself may write
    // (the Allocator interface fills fresh memory with undefined in
    // safe builds, which valgrind also tracks). The sentinel must differ
    // from Zig's 0xAA undefined pattern so that any write is visible.
    const sentinel: u8 = 0x5A;
    @memset(backing, sentinel);

    // Every preheated item is handed out untouched and without going
    // back to the page allocator, and destroying it doesn't touch it.
    var items: [preheat]PagePool.ItemPtr = undefined;
    for (&items) |*item| {
        item.* = try pool.pages.create();
        try testing.expectEqual(preheat * std_size, fba.end_index);
        try testing.expect(std.mem.allEqual(u8, item.*, sentinel));
    }
    for (items) |item| pool.pages.destroy(item);
    try testing.expect(std.mem.allEqual(u8, backing, sentinel));
}

test "PageList memory pool fast path does not allocate" {
    const testing = std.testing;
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});

    var pool: MemoryPool = try .init(
        testing.allocator,
        counting.allocator(),
        page_preheat,
    );
    defer pool.deinit();
    try testing.expectEqual(page_preheat, counting.allocations);

    // Cycle a few thousand pages through the preheated items. As long
    // as no more than the preheat are live at once, create is a
    // free-list pop and never touches the page allocator.
    var items: [page_preheat]PagePool.ItemPtr = undefined;
    for (0..1024) |_| {
        for (&items) |*item| item.* = try pool.pages.create();
        for (items) |item| pool.pages.destroy(item);
    }
    try testing.expectEqual(page_preheat, counting.allocations);
    try testing.expectEqual(0, counting.deallocations);

    // Going past the preheat allocates the extra items once; they are
    // recycled from then on.
    var extra: [page_preheat + 2]PagePool.ItemPtr = undefined;
    for (0..1024) |_| {
        for (&extra) |*item| item.* = try pool.pages.create();
        for (extra) |item| pool.pages.destroy(item);
    }
    try testing.expectEqual(extra.len, counting.allocations);
    try testing.expectEqual(0, counting.deallocations);
}
