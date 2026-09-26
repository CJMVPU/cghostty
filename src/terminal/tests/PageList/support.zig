//! Shared fixtures and aliases for PageList regression tests.
pub const PageList = @import("../../PageList.zig");
pub const std = @import("std");
pub const Allocator = std.mem.Allocator;
pub const assert = @import("../../../quirks.zig").inlineAssert;
pub const kitty = @import("../../kitty.zig");
pub const point = @import("../../point.zig");
pub const pagepkg = @import("../../page.zig");
pub const stylepkg = @import("../../style.zig");
pub const size = @import("../../size.zig");
pub const Page = pagepkg.Page;
pub const page_preheat = PageList.TestAccess.page_preheat;
pub const List = PageList.List;
pub const Node = PageList.TestAccess.Node;
pub const std_capacity = PageList.TestAccess.std_capacity;
pub const std_size = PageList.TestAccess.std_size;
pub const PagePool = PageList.TestAccess.PagePool;
pub const MemoryPool = PageList.MemoryPool;
pub const Viewport = PageList.Viewport;
pub const initialCapacity = PageList.TestAccess.initialCapacity;
pub const init_tw = PageList.TestAccess.init_tw;
pub const init = PageList.init;
pub const initPages_tw = PageList.TestAccess.initPages_tw;
pub const Clone = PageList.Clone;
pub const resizeWithoutReflow = PageList.TestAccess.resizeWithoutReflow;
pub const trimTrailingBlankRows = PageList.TestAccess.trimTrailingBlankRows;
pub const Scrollbar = PageList.Scrollbar;
pub const IncrementalCompressionState = PageList.TestAccess.IncrementalCompressionState;
pub const IncrementalCompressionResult = PageList.IncrementalCompressionResult;
pub const CompressionIterator = PageList.TestAccess.CompressionIterator;
pub const incremental_compression_max_inspected = PageList.TestAccess.incremental_compression_max_inspected;
pub const compressPage_tw = PageList.TestAccess.compressPage_tw;
pub const compressPage = PageList.TestAccess.compressPage;
pub const destroyNode = PageList.TestAccess.destroyNode;
pub const PageIterator = PageList.PageIterator;
pub const totalRows = PageList.TestAccess.totalRows;
pub const growRows = PageList.TestAccess.growRows;
pub const markDirty = PageList.TestAccess.markDirty;
pub const Pin = PageList.Pin;
pub const Cell = PageList.Cell;
pub const TestSupport = PageList.TestSupport;

pub fn mixedWidthPinListForTest(alloc: Allocator) !PageList {
    var result = try init(alloc, .{ .cols = 2, .rows = 1 });
    errdefer result.deinit();

    // This deliberately constructs a layout that normal PageList operations
    // do not expose yet. Keep integrity checks paused through deinit so the
    // fixture can exercise mixed-width traversal in isolation.
    result.pauseIntegrityChecks(true);

    inline for (.{ 4, 3 }) |cols| {
        const node = try createPage(&result, .{ .cap = .{
            .cols = cols,
            .rows = 1,
        } });
        node.page().size.rows = 1;
        result.pages.append(node);
        result.total_rows += 1;
    }

    // Desired geometry is wider than the first and last stored pages.
    result.cols = 4;
    return result;
}

/// Grow a test PageList until it contains at least `count` complete history
/// pages. The production cold-page boundary is intentionally reused here so
/// tests do not duplicate the row-to-page arithmetic.
pub fn growColdPagesForTest(self: *PageList, count: usize) !void {
    while (true) {
        const active_node = self.getTopLeft(.active).node;
        var cold_count: usize = 0;
        var current = self.pages.first;
        while (current) |node| : (current = node.next) {
            if (node == active_node) break;
            cold_count += 1;
        }

        if (cold_count >= count) return;
        _ = try self.grow();
    }
}

/// Fill the current tail page to capacity without allocating a successor.
/// Capturing the tail before the loop makes this stop at the allocation
/// boundary needed by bounded-pruning tests.
pub fn fillLastPageForTest(self: *PageList) !void {
    const last = self.pages.last.?;
    while (last.rows() < last.capacity().rows) _ = try self.grow();
}

/// Verify every live page belongs to the current validity epoch, has an
/// allocated generation below the next serial, and validates through the same
/// pointer-plus-generation lookup used by external references.
pub fn expectLivePageSerialsValidForTest(self: *const PageList) !void {
    const testing = std.testing;
    var node = self.pages.first;
    while (node) |live| : (node = live.next) {
        try testing.expect(live.serial >= self.page_serial_epoch);
        try testing.expect(live.serial < self.page_serial);
        try testing.expect(self.nodeIsValid(live, live.serial));
    }
}

pub const createPage = PageList.TestAccess.createPage;
pub const nodeIsCompressed = PageList.TestAccess.nodeIsCompressed;
pub const nodeMetadata = PageList.TestAccess.nodeMetadata;
pub const minMaxLines = PageList.TestAccess.minMaxLines;
