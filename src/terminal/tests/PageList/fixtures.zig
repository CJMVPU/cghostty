//! Detached page construction for tests only. Production allocation hooks are
//! available through PageList.TestAccess only in test builds.
const std = @import("std");
const Allocator = std.mem.Allocator;
const PageList = @import("../../PageList.zig");
const Capacity = @import("../../page.zig").Capacity;
const Page = @import("../../page.zig").Page;
const size = @import("../../size.zig");
const List = PageList.List;
const MemoryPool = PageList.MemoryPool;
const Pin = PageList.Pin;
const Limits = PageList.TestAccess.Limits;
const PagePool = PageList.TestAccess.PagePool;
const createPageExt = PageList.TestAccess.createPageExt;
const destroyNodeExt = PageList.TestAccess.destroyNodeExt;
const initTrackedPins = PageList.TestAccess.initTrackedPins;
const Options = PageList.Options;
const pageAllocator = PageList.TestAccess.pageAllocator;
const page_preheat = PageList.TestAccess.page_preheat;

/// Allocate a new page using the PageList's memory pools.
///
/// The page is detached: it doesn't contribute to the memory limits or
/// row counts or anything in the PageList. The caller must call `finalize`
/// to add it to the PageList at the appropriate place, or `deinit` to
/// throw it away.
pub fn allocatePage(
    self: *PageList,
    capacity: Capacity,
) Allocator.Error!PageAllocation {
    return .{
        .destination = self,
        .node = try createPageExt(
            &self.pool,
            .{ .cap = capacity },
            &self.page_serial,
            null,
        ),
    };
}

/// One PageList-pooled page which has not yet joined the live page sequence.
pub const PageAllocation = struct {
    destination: *PageList,
    node: ?*List.Node,

    /// Return the fresh page storage for the caller to populate.
    pub fn page(self: *PageAllocation) *Page {
        return self.node.?.pageAssumeResident();
    }

    /// Release an uncommitted page back to its PageList's pools.
    ///
    /// This is safe to call after `finalize` succeeds, so callers can defer
    /// it unconditionally.
    pub fn deinit(self: *PageAllocation) void {
        const node = self.node orelse return;
        destroyNodeExt(
            &self.destination.pool,
            node,
            null,
        );
        self.node = null;
    }

    pub const Location = union(enum) {
        /// Prepend the page to the start of the list (oldest history).
        prepend,
    };

    /// Finalize this complete page and transfer its ownership to the PageList.
    /// The parameter determines where it goes into the PageList.
    ///
    /// Existing pages and tracked pins keep their identity. A pinned viewport
    /// keeps showing the same content while its cached absolute row offset
    /// moves down by the number of newly inserted rows.
    pub fn finalize(self: *PageAllocation, location: Location) FinalizeError!void {
        switch (location) {
            .prepend => return try self.prepend(),
        }
    }

    pub const FinalizeError = error{
        InvalidPageDimensions,
        RowCountOverflow,
        PageSizeOverflow,
        MaxSizeExceeded,
        MaxLinesExceeded,
    };

    fn prepend(self: *PageAllocation) FinalizeError!void {
        const destination = self.destination;
        const node = self.node.?;

        // Validate the populated page and all resulting accounting before
        // publishing the detached node into the live list.
        if (node.cols() == 0 or node.rows() == 0) return error.InvalidPageDimensions;
        const total_rows = std.math.add(
            usize,
            destination.total_rows,
            node.rows(),
        ) catch return error.RowCountOverflow;
        const node_size: usize = switch (node.owned) {
            .pool => PagePool.item_size,
            .heap => node.pageAssumeResident().memory.len,
        };
        const page_size = std.math.add(
            usize,
            destination.page_size,
            node_size,
        ) catch return error.PageSizeOverflow;

        // Restored history is exact data, so reject a page which cannot
        // coexist with the receiving PageList's configured limits.
        if (page_size > destination.limits.max(.bytes)) {
            return error.MaxSizeExceeded;
        }
        if (total_rows - destination.rows > destination.limits.max(.lines)) {
            return error.MaxLinesExceeded;
        }

        // No fallible work remains. Publish the page and update every cached
        // quantity affected by inserting rows above the existing first page.
        errdefer comptime unreachable;
        destination.pages.prepend(node);
        destination.page_size = page_size;
        destination.total_rows = total_rows;
        if (destination.viewport == .pin) {
            if (destination.viewport_pin_row_offset) |*offset| {
                offset.* += node.rows();
            }
        }
        PageList.TestAccess.compressionActivity(&destination.page_compression);

        destination.assertIntegrity();
        self.node = null;
    }
};

/// Build up a PageList manually from a set of Pages.
///
/// This data structure is transactional: `deinit` releases every page
/// until `finish` is called. This keeps the ownership clear: a complete
/// PageList either owns all its pages or doesn't.
///
/// This was specifically built to help facilitate snapshot decoding
/// which transfers pages directly, but could be generally useful
/// for other purposes as well.
pub const Builder = struct {
    pool: MemoryPool,
    pages: List = .{},
    page_serial: u64 = 0,
    page_size: usize = 0,
    options: Options,
    finished: bool = false,

    /// Initialize an empty builder. The options are the final state
    /// of the PageList and some validation is done on the finish call
    /// to ensure you built up a proper PageList according to those options.
    pub fn init(
        alloc: Allocator,
        options: Options,
    ) Allocator.Error!Builder {
        return .{
            .pool = try MemoryPool.init(
                alloc,
                pageAllocator(),
                page_preheat,
            ),
            .options = options,
        };
    }

    /// Release all pages when restoration does not finish.
    ///
    /// This is safe to call after `finish` succeeds, so callers can defer it
    /// unconditionally.
    pub fn deinit(self: *Builder) void {
        if (self.finished) return;

        // Free all our in-progress pages
        while (self.pages.popFirst()) |node| destroyNodeExt(
            &self.pool,
            node,
            &self.page_size,
        );
        // Free memory pool
        self.pool.deinit();
        self.* = undefined;
    }

    /// Allocate a new page into the PageList with the given capacity.
    ///
    /// The caller can then take this page and populate it. When `finish`
    /// is called, ownership is transferred to the resulting PageList.
    /// Until then, this Builder owns the page.
    pub fn allocatePage(
        self: *Builder,
        capacity: Capacity,
    ) Allocator.Error!*Page {
        const node = try createPageExt(
            &self.pool,
            .{ .cap = capacity },
            &self.page_serial,
            &self.page_size,
        );
        self.pages.append(node);
        return node.pageAssumeResident();
    }

    pub const FinishError = Allocator.Error || error{
        InvalidDimensions,
        InvalidPageDimensions,
        NoPages,
        InsufficientRows,
    };

    /// Validate the decoded pages and transfer them into a live PageList.
    /// After this succeeds, `deinit` is a no-op because all resources have
    /// transferred to the PageList.
    pub fn finish(self: *Builder) FinishError!PageList {
        // These are basic validations but they're cheap to do and
        // we want to be careful we don't let corruption from untrusted
        // sources into our PageList which asserts this.
        if (self.options.cols == 0 or self.options.rows == 0) {
            return error.InvalidDimensions;
        }
        if (self.pages.first == null) return error.NoPages;

        // Manually count our total rows at this point which we'll
        // need for our PageList cache as well as a safety check.
        const total_rows: usize = total_rows: {
            var total_rows: usize = 0;
            var node = self.pages.first;
            while (node) |current| : (node = current.next) {
                if (current.cols() == 0 or current.rows() == 0) {
                    return error.InvalidPageDimensions;
                }
                total_rows += current.rows();
            }
            if (total_rows < self.options.rows) return error.InsufficientRows;
            break :total_rows total_rows;
        };

        // Get our active pin
        const active_top: Pin = active_top: {
            var rem = self.options.rows;
            var node = self.pages.last;
            while (node) |current| : (node = current.prev) {
                if (rem <= current.rows()) break :active_top .{
                    .node = current,
                    .y = current.rows() - rem,
                };
                rem -= current.rows();
            } else unreachable;
        };

        // Set our viewport up to the active
        const viewport_pin = try self.pool.pins.create();
        errdefer self.pool.pins.destroy(viewport_pin);
        viewport_pin.* = active_top;

        // Setup our one viewport tracked pin
        var tracked_pins = try initTrackedPins(self.pool.alloc, viewport_pin);
        errdefer tracked_pins.deinit(self.pool.alloc);

        // Initialize limits
        var limits: Limits = .init(self.options.cols, self.options.rows);
        limits.set(.bytes, self.options.max_size);
        limits.set(.lines, self.options.max_lines);

        const result: PageList = .{
            .cols = self.options.cols,
            .rows = self.options.rows,
            .pool = self.pool,
            .pages = self.pages,
            .page_serial = self.page_serial,
            .page_serial_epoch = 0,
            .page_size = self.page_size,
            .limits = limits,
            .total_rows = total_rows,
            .tracked_pins = tracked_pins,
            .viewport = .{ .active = {} },
            .viewport_pin = viewport_pin,
            .viewport_pin_row_offset = null,
        };
        result.assertIntegrity();
        self.finished = true;
        return result;
    }
};
