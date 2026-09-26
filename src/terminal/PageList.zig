//! Maintains a linked list of pages to make up a terminal screen
//! and provides higher level operations on top of those pages to
//! make it slightly easier to work with.
const PageList = @This();

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const fastmem = @import("../fastmem.zig");
const simd = @import("../simd/main.zig");
const tripwire = @import("../tripwire.zig");
const DoublyLinkedList = @import("../datastruct/main.zig").IntrusiveDoublyLinkedList;
const datastruct = @import("../datastruct/main.zig");
const compression = @import("compress.zig");
const highlight = @import("highlight.zig");
const hyperlink = @import("hyperlink.zig");
const kitty = @import("kitty.zig");
const terminal_mem = @import("mem.zig");
const point = @import("point.zig");
const pagepkg = @import("page.zig");
const stylepkg = @import("style.zig");
const size = @import("size.zig");
const OffsetBuf = size.OffsetBuf;
const Capacity = pagepkg.Capacity;
const Page = pagepkg.Page;
const Row = pagepkg.Row;

const log = std.log.scoped(.page_list);

/// Preheat demand-paged pool entries; this initially costs only address space.
const page_preheat = 4;

/// The number of nodes we preheat the node pool with. Unlike pages, nodes
/// are ordinary heap memory so every idle preheated node costs real
/// memory. A new PageList needs exactly one node for its first page, so
/// we preheat that one and let the pool grow on demand.
const node_preheat = 1;

/// The number of pins we preheat the pin pool with: the viewport pin that
/// every PageList tracks and the cursor pin that every Screen tracks.
/// Selections, searches, and so on grow the pool on demand.
const pin_preheat = 2;

/// The list of pages in the screen. These are expected to be in order
/// where the first page is the topmost page (scrollback) and the last is
/// the bottommost page (the current active page).
pub const List = DoublyLinkedList(Node);

/// A single node within the PageList linked list.
///
/// This isn't pub because you can access the type via List.Node.
const Node = struct {
    prev: ?*Node = null,
    next: ?*Node = null,
    data: Data,
    serial: u64,

    /// How the backing memory of the embedded Page was allocated. Pool-owned
    /// memory is always a full standard-size item from the memory
    /// pool, regardless of the page layout size. Heap-owned memory
    /// is allocated directly with the page allocator and is exactly
    /// `Page.memory.len` bytes.
    ///
    /// This must never be inferred from the memory length: heap-owned
    /// pages can be smaller than the standard size (e.g. compacted
    /// pages), and returning one to the pool would corrupt it.
    ///
    /// This has no default on purpose so that every construction site
    /// is forced to make an explicit decision.
    owned: Owned,

    /// The physical representation of the page contents.
    ///
    /// Both states retain the same `Page.memory` virtual mapping and the same
    /// `Page` metadata. A resident page can access the mapping directly since
    /// it is, well, resident.
    ///
    /// A compressed page owns an encoded copy while the physical memory
    /// behind the raw mapping is discarded. HOWEVER, we retain the
    /// virtual allocation so that restoration is infallible.
    const Data = union(enum) {
        resident: Page,
        compressed: compression.Page,
    };

    const Owned = enum { pool, heap };

    /// The backing-memory representation currently stored by this node.
    pub const Storage = enum { resident, compressed };

    /// Return the terminal page stored in this node.
    ///
    /// WARNING: This will DECOMPRESS compressed pages! Only use this if
    /// you need access to the underlying memory. If you only need access to
    /// metadata (row, col counts etc) then use the other metadata functions.
    pub inline fn page(self: *Node) *Page {
        return switch (self.data) {
            .resident => |*page_| page_,
            .compressed => self.restore(.preserve),
        };
    }

    /// Return the terminal page only when its raw memory is resident.
    ///
    /// Unlike `page`, this never restores a compressed node. This is useful
    /// for diagnostics which can display node metadata without touching the
    /// discarded mapping, but may inspect page contents when they are already
    /// available.
    pub inline fn pageIfResident(self: *Node) ?*Page {
        return switch (self.data) {
            .resident => |*page_| page_,
            .compressed => null,
        };
    }

    /// Read-only page with full memory access that doesn't change
    /// this node's storage state: if a node is compressed it remains
    /// compressed.
    ///
    /// Resident pages are borrowed directly. So they're basically free.
    ///
    /// Compressed pages are decoded into an independently owned Page
    /// by the caller so callers can inspect their contents. Because resident
    /// pages are still borrowed, you have to continue to have exclusive
    /// access to the PageList during this operation.
    pub const PreservedPage = union(enum) {
        borrowed: *const Page,
        owned: struct {
            page: Page,
            alloc: Allocator,
        },

        /// Return the read-only page represented by this value.
        pub fn page(self: *const PreservedPage) *const Page {
            return switch (self.*) {
                .borrowed => |page_| page_,
                .owned => |*owned| &owned.page,
            };
        }

        /// Release storage owned by this preserved page.
        pub fn deinit(self: *PreservedPage) void {
            switch (self.*) {
                .borrowed => {},
                // The clone buffer came from the caller's allocator rather
                // than Page's OS allocator, so it must not use Page.deinit.
                .owned => |*owned| owned.alloc.free(owned.page.memory),
            }
            self.* = undefined;
        }
    };

    /// Return read-only page contents without changing this node's storage.
    ///
    /// `alloc` is unused for a resident node. A compressed node uses it for an
    /// exact-sized, page-aligned decode buffer owned by the returned value.
    ///
    /// The caller must call `PreservedPage.deinit` when finished. See
    /// `PreservedPage` for the synchronization required by its borrowed
    /// resident representation.
    pub fn pagePreservingState(
        self: *const Node,
        alloc: Allocator,
    ) Allocator.Error!PreservedPage {
        return switch (self.data) {
            .resident => |*page_| .{ .borrowed = page_ },
            .compressed => |*compressed| owned: {
                const memory = try alloc.alignedAlloc(
                    u8,
                    .fromByteUnits(std.heap.page_size_min),
                    compressed.page.memory.len,
                );

                const page_ = compressed.cloneBuf(memory) catch |err| {
                    // The encoded data was produced by our codec and remains
                    // immutable while compressed. Failure is internal
                    // corruption, matching the normal restoration boundary.
                    switch (err) {
                        error.TruncatedInput,
                        error.InvalidOffset,
                        error.OutputTooSmall,
                        error.OutputSizeMismatch,
                        => {},
                    }

                    alloc.free(memory);
                    log.err("failed to clone compressed page err={}", .{err});
                    @panic("failed to clone compressed terminal page");
                };

                break :owned .{ .owned = .{
                    .page = page_,
                    .alloc = alloc,
                } };
            },
        };
    }

    /// Return the node's backing-memory representation without restoring it.
    pub inline fn storage(self: *const Node) Storage {
        return switch (self.data) {
            .resident => .resident,
            .compressed => .compressed,
        };
    }

    /// Return a page which the caller knows is already resident.
    ///
    /// This avoids the representation check in hot paths which already hold
    /// live pointers into the page mapping. Such pointers are only valid while
    /// the page is resident. Prefer `page` unless the caller can establish
    /// that invariant independently.
    pub inline fn pageAssumeResident(self: *Node) *Page {
        return &self.data.resident;
    }

    /// Return the number of populated rows without accessing page memory.
    pub inline fn rows(self: *const Node) size.CellCountInt {
        return self.metadata().size.rows;
    }

    /// Return the current column count without accessing page memory.
    pub inline fn cols(self: *const Node) size.CellCountInt {
        return self.metadata().size.cols;
    }

    /// Return the page capacity without accessing page memory.
    pub inline fn capacity(self: *const Node) Capacity {
        return self.metadata().capacity;
    }

    /// Return the embedded Page metadata without restoring its memory.
    inline fn metadata(self: *const Node) *const Page {
        return switch (self.data) {
            .resident => |*page_| page_,
            .compressed => |*page_| &page_.page,
        };
    }

    const RestoreMode = enum {
        /// Decode the compressed representation back into the raw mapping.
        preserve,

        /// Discard the compressed representation without decoding it. The
        /// caller must not read the page contents before overwriting them.
        discard,
    };

    /// Restore this node to the resident representation.
    ///
    /// Preserve mode reconstructs the page contents and is used by `page`.
    /// Discard mode skips decoding for callers which will overwrite or destroy
    /// the page. Both modes recommit the retained mapping, free the encoded
    /// allocation, and leave the node in a valid resident state.
    noinline fn restore(self: *Node, comptime mode: RestoreMode) *Page {
        const compressed = switch (self.data) {
            .resident => |*page_| return page_,
            .compressed => |*page_| page_,
        };

        // Decommit only discarded the physical pages. Recommit prepares the
        // still-reserved mapping for decoding or reuse by the caller.
        terminal_mem.recommit(compressed.page.memory);

        const restored = switch (mode) {
            .preserve => compressed.restore() catch |err| {
                // Compressed nodes retain the immutable encoding and exact
                // output mapping used to create them. Any decode error is an
                // internal codec bug or memory corruption. Keep this switch
                // exhaustive so new decoder errors require classification.
                switch (err) {
                    error.TruncatedInput,
                    error.InvalidOffset,
                    error.OutputTooSmall,
                    error.OutputSizeMismatch,
                    => {},
                }

                log.err("failed to restore compressed page err={}", .{err});
                @panic("failed to restore compressed terminal page");
            },

            .discard => compressed.page,
        };

        // Remove our compressed data
        compressed.deinit();

        // We're now a resident, non-compressed node.
        self.data = .{ .resident = restored };
        return &self.data.resident;
    }

    inline fn isCompressed(self: *const Node) bool {
        return switch (self.data) {
            .resident => false,
            .compressed => true,
        };
    }
};

/// The memory pool we get page nodes from.
///
/// We don't use a std memory pool here because it is backed by an arena
/// and we end up paying a lot of wasted memory for the growth factor when
/// in practice we don't usually use many nodes.
///
/// We don't need the "untouched" property of our UntouchedPool but
/// this gives us a GPA-allocated pool so we reuse it here.
const NodePool = datastruct.UntouchedPool(List.Node, .of(List.Node));

/// The standard page capacity that we use as a starting point for
/// all pages. This is chosen as a sane default that fits most terminal
/// usage to support using our pool.
const std_capacity = pagepkg.std_capacity;

/// The byte size required for a standard page.
const std_size = Page.layout(std_capacity).total_size;

/// True when the page pool is the wasm page pool, which recycles items
/// through a free list shared by the whole module instance instead of
/// dying with the pool.
///
/// Test builds use the native pool even on wasm so that pool memory goes
/// through the testing allocator and participates in leak detection.
/// The memory pool we use for page memory buffers. We use a separate pool
/// so we can allocate these with a page allocator. We have to use a page
/// allocator because we need memory that is zero-initialized and page-aligned.
const PagePool = untouched: {
    // Untouched pools never read/write to the items so that we can
    // use demand-paging on operating systems that support it. This makes
    // it so that an idle item in the pool costs no physical memory,
    // only virtual memory.
    //
    // Contract for PageList is that every path that returns an item
    // to the pool must zero it.
    break :untouched datastruct.UntouchedPool(
        [std_size]u8,
        .fromByteUnits(std.heap.page_size_min),
    );
};

/// List of pins, known as "tracked" pins. These are pins that are kept
/// up to date automatically through page-modifying operations.
const PinSet = std.AutoArrayHashMapUnmanaged(*Pin, void);
const PinPool = std.heap.memory_pool.Managed(Pin);

/// The pool of memory used for a pagelist. This can be shared between
/// multiple pagelists but it is not threadsafe.
pub const MemoryPool = struct {
    alloc: Allocator,
    nodes: NodePool,
    pages: PagePool,
    pins: PinPool,

    pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

    pub fn init(
        gen_alloc: Allocator,
        page_alloc: Allocator,
        preheat: usize,
    ) Allocator.Error!MemoryPool {
        var node_pool = try NodePool.initCapacity(gen_alloc, gen_alloc, node_preheat);
        errdefer node_pool.deinit();
        var page_pool = try PagePool.initCapacity(gen_alloc, page_alloc, preheat);
        errdefer page_pool.deinit();
        var pin_pool = try PinPool.initCapacity(gen_alloc, pin_preheat);
        errdefer pin_pool.deinit();
        return .{
            .alloc = gen_alloc,
            .nodes = node_pool,
            .pages = page_pool,
            .pins = pin_pool,
        };
    }

    pub fn deinit(self: *MemoryPool) void {
        self.pages.deinit();
        self.nodes.deinit();
        self.pins.deinit();
    }

    pub fn reset(self: *MemoryPool, mode: ResetMode) void {
        _ = self.pages.reset(mode);
        _ = self.nodes.reset(mode);
        _ = self.pins.reset(mode);
    }
};

/// The memory pool we get page nodes, pages from.
pool: MemoryPool,

/// The list of pages in the screen.
pages: List,

/// The next globally unique reference generation for this PageList. A
/// generation is assigned whenever a page is allocated, reused as new, or
/// changed in place such that existing page coordinates are no longer stable.
///
/// The serial number can be used to detect whether the page is identical
/// to the page that was originally referenced by a pointer. Since we reuse
/// and pool memory, pointer stability is not guaranteed, but the serial
/// will always be different for different page generations.
///
/// Developer note: we never do overflow checking on this. If we created
/// a new page every second it'd take 584 billion years to overflow. We're
/// going to risk it.
page_serial: u64,

/// The first serial in the current whole-list validity epoch. Only `reset`
/// advances this value, immediately before rebuilding every page. It is not
/// the generation of the first page or the exact minimum live generation.
/// Page generations are not monotonic in list order: replacement and split
/// operations can put a fresh generation before older live pages.
///
/// A generation below this epoch is definitely invalid, allowing O(1)
/// rejection in `nodeIsValid` and bulk removal of pre-reset search results.
/// A generation at or above it is only potentially valid and must still be
/// checked against the live list before its coordinates are used.
page_serial_epoch: u64,

/// Byte size of the raw backing mappings owned by active page nodes. This is
/// logical scrollback accounting and does not change while a mapping is
/// decommitted. It excludes encoded storage and unused preheated pool items.
page_size: usize,

/// Continuation state for incremental page compression. This allows
/// compress(.incremental) to work. More details on all that there and
/// in the state struct.
page_compression: IncrementalCompressionState = .{},

/// A node available for immediate reuse by createPage, bypassing the
/// memory pool round trip. This is only set during column reflow
/// (resizeCols), which destroys one source page for roughly every
/// destination page it creates: returning a page buffer to the pool
/// decommits it and taking one back recommits it, and that syscall
/// pair per page is a significant part of reflow cost. Always null
/// outside of an in-progress reflow.
recycle_node: ?*List.Node = null,

/// Limits for scrollback.
limits: Limits,

/// The total number of rows represented by this PageList. This is used
/// specifically for scrollbar information so we can have the total size.
total_rows: usize,

/// The list of tracked pins. These are kept up to date automatically.
tracked_pins: PinSet,

/// The top-left of certain parts of the screen that are frequently
/// accessed so we don't have to traverse the linked list to find them.
///
/// For other tags, don't need this:
///   - screen: pages.first
///   - history: active row minus one
///
viewport: Viewport,

/// The pin used for when the viewport scrolls. This is always pre-allocated
/// so that scrolling doesn't have a failable memory allocation. This should
/// never be access directly; use `viewport`.
viewport_pin: *Pin,

/// The row offset from the top that the viewport pin is at. We
/// store the offset from the top because it doesn't change while more
/// data is printed to the terminal.
///
/// This is null when it isn't calculated. It is calculated on demand
/// when the viewportRowOffset function is called, because it is only
/// required for certain operations such as rendering the scrollbar.
///
/// In order to make this more efficient, in many places where the value
/// would be invalidated, we update it in-place instead. This is key to
/// keeping our performance decent in normal cases since recalculating
/// this from scratch, depending on the size of the scrollback and position
/// of the pin, can be very expensive.
///
/// This is only valid if viewport is `pin`. Every other offset is
/// self-evident or quick to calculate.
viewport_pin_row_offset: ?usize,

/// The current desired screen dimensions. I say "desired" because individual
/// pages may still be a different size and not yet reflowed since we lazily
/// reflow text.
cols: size.CellCountInt,
rows: size.CellCountInt,

/// If this is true then verifyIntegrity will do nothing. This is
/// only present with runtime safety enabled.
pause_integrity_checks: if (build_options.slow_runtime_safety) usize else void =
    if (build_options.slow_runtime_safety) 0 else {},

/// The viewport location.
pub const Viewport = union(enum) {
    /// The viewport is pinned to the active area. By using a specific marker
    /// for this instead of tracking the row offset, we eliminate a number of
    /// memory writes making scrolling faster.
    active,

    /// The viewport is pinned to the top of the screen, or the farthest
    /// back in the scrollback history.
    top,

    /// The viewport is pinned to a tracked pin. The tracked pin is ALWAYS
    /// s.viewport_pin hence this has no value. We force that value to prevent
    /// allocations.
    pin,
};

/// Calculates the initial capacity for a new page for a given column
/// count. This will attempt to fit within std_size at all times so we
/// can use our memory pool, but if cols is too big, this will return a
/// larger capacity.
///
/// The returned capacity is always guaranteed to layout properly (not
/// overflow). We are able to support capacities up to the maximum int
/// value of cols, so this will never overflow.
fn initialCapacity(cols: size.CellCountInt) Capacity {
    // This is an important invariant that ensures that this function
    // can never return an error. We verify here that our standard capacity
    // when increased to maximum possible columns can always support at
    // least one row in memory.
    //
    // IF THIS EVER FAILS: We probably need to modify our logic below
    // to reduce other elements of the capacity (styles, graphemes, etc.).
    // But, instead, I recommend taking a step back and re-evaluating
    // life choices.
    comptime {
        var cap = std_capacity;
        cap.cols = std.math.maxInt(size.CellCountInt);
        const layout = Page.layout(cap);
        assert(layout.total_size <= size.max_page_size);
    }

    if (std_capacity.adjust(
        .{ .cols = cols },
    )) |cap| {
        // If we can adjust our standard capacity, we fit within the
        // standard size and we're good!
        return cap;
    } else |err| {
        // Ensure our error set doesn't change.
        comptime assert(@TypeOf(err) == error{OutOfMemory});
    }

    // This code path means that our standard capacity can't even
    // accommodate our column count! The only solution is to increase
    // our capacity and go non-standard.
    var cap: Capacity = std_capacity;
    cap.cols = cols;
    return cap;
}

/// Returns the allocator used for underlying page allocations.
inline fn pageAllocator() Allocator {
    // In tests we use our testing allocator so we can detect leaks.
    if (builtin.is_test) return std.testing.allocator;

    // On macOS we want to tag our memory so we can assign it to our
    // core terminal usage.
    const mach = @import("../os/mach.zig");
    return mach.taggedPageAllocator(.application_specific_1);
}

const init_tw = tripwire.module(enum {
    init_memory_pool,
    init_pages,
    viewport_pin,
    viewport_pin_track,
}, init);

pub const Options = struct {
    /// The initial active-area size. This can be resized with `resize`.
    cols: size.CellCountInt,
    rows: size.CellCountInt,

    /// The maximum number of bytes allocated for pages. The effective limit
    /// is raised when necessary to hold the active area. Null is unlimited.
    max_size: ?usize = null,

    /// The maximum number of scrollback rows, excluding the active
    /// area. Rows are physical (viewed) rows, so a wrapped row counts as
    /// multiple rows. Max line pruning only happens at page-boundaries
    /// (the minimum internal allocation size) so in practice the max lines
    /// is always slightly larger than configured.
    ///
    /// Null is unlimited.
    max_lines: ?usize = null,
};

/// Initialize the page. The top of the first page in the list is always the
/// top of the active area of the screen (important knowledge for quickly
/// setting up cursors in Screen).
///
/// `max_size` is the maximum number of bytes that will be allocated for
/// pages. If this is smaller than the bytes required to show the viewport
/// then max_size will be ignored and the viewport will be shown, but no
/// scrollback will be created. max_size is always rounded down to the nearest
/// terminal page size (not virtual memory page), otherwise we would always
/// slightly exceed max_size in the limits.
///
/// `max_lines` is the maximum number of physical rows retained as scrollback,
/// excluding the active area. It is a page-granular heuristic: at least one
/// standard page worth of rows is permitted and only complete historical
/// pages are removed.
///
/// If either limit is null then that dimension has no defined limit and the
/// screen will grow forever. In reality, the limit is set to the amount your
/// computer can address in memory. If you somehow require more than that (due
/// to disk paging) then please contribute that yourself and perhaps search
/// deep within yourself to find out why you need that.
pub fn init(
    alloc: Allocator,
    opts: Options,
) Allocator.Error!PageList {
    const tw = init_tw;
    const cols = opts.cols;
    const rows = opts.rows;

    // The screen starts with a single page that is the entire viewport,
    // and we'll split it thereafter if it gets too large and add more as
    // necessary.
    try tw.check(.init_memory_pool);
    var pool = try MemoryPool.init(
        alloc,
        pageAllocator(),
        page_preheat,
    );
    errdefer pool.deinit();

    try tw.check(.init_pages);
    var page_serial: u64 = 0;
    const page_list, const page_size = try initPages(
        &pool,
        &page_serial,
        cols,
        rows,
    );
    errdefer releasePages(&pool, page_list);

    var limits: Limits = .init(cols, rows);
    limits.set(.bytes, opts.max_size);
    limits.set(.lines, opts.max_lines);

    // We always track our viewport pin to ensure this is never an allocation
    try tw.check(.viewport_pin);
    const viewport_pin = try pool.pins.create();
    viewport_pin.* = .{ .node = page_list.first.? };

    try tw.check(.viewport_pin_track);
    var tracked_pins = try initTrackedPins(pool.alloc, viewport_pin);
    errdefer tracked_pins.deinit(pool.alloc);

    errdefer comptime unreachable;
    const result: PageList = .{
        .cols = cols,
        .rows = rows,
        .pool = pool,
        .pages = page_list,
        .page_serial = page_serial,
        .page_serial_epoch = 0,
        .page_size = page_size,
        .limits = limits,
        .total_rows = rows,
        .tracked_pins = tracked_pins,
        .viewport = .{ .active = {} },
        .viewport_pin = viewport_pin,
        .viewport_pin_row_offset = null,
    };
    result.assertIntegrity();
    return result;
}

/// Create the tracked pin set for a new PageList with the viewport pin
/// already tracked. The set is sized for exactly the viewport pin and the
/// cursor pin that every Screen tracks.
fn initTrackedPins(alloc: Allocator, viewport_pin: *Pin) Allocator.Error!PinSet {
    var set: PinSet = .{};
    errdefer set.deinit(alloc);
    try set.entries.setCapacity(alloc, pin_preheat);
    set.putAssumeCapacityNoClobber(viewport_pin, {});
    return set;
}

const initPages_tw = tripwire.module(enum {
    page_node,
    page_buf_std,
    page_buf_non_std,
}, initPages);

fn initPages(
    pool: *MemoryPool,
    serial: *u64,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) Allocator.Error!struct { List, usize } {
    const tw = initPages_tw;

    var page_list: List = .{};
    var page_size: usize = 0;

    // Add pages as needed to create our initial viewport.
    const cap = initialCapacity(cols);
    const layout = Page.layout(cap);
    const pooled = layout.total_size <= std_size;
    const page_alloc = pool.pages.allocator;

    // Guaranteed by comptime checks in initialCapacity but
    // redundant here for safety.
    assert(layout.total_size <= size.max_page_size);

    // If we have an error, we need to release the pages we created.
    errdefer releasePages(pool, page_list);

    var rem = rows;
    while (rem > 0) {
        try tw.check(.page_node);
        const node = try pool.nodes.create();
        errdefer pool.nodes.destroy(node);

        const page_buf = if (pooled) buf: {
            try tw.check(.page_buf_std);
            const buf = try pool.pages.create();
            terminal_mem.recommit(buf);
            break :buf buf;
        } else buf: {
            try tw.check(.page_buf_non_std);
            break :buf try page_alloc.alignedAlloc(
                u8,
                .fromByteUnits(std.heap.page_size_min),
                layout.total_size,
            );
        };
        errdefer if (pooled)
            pool.pages.destroy(page_buf)
        else
            page_alloc.free(page_buf);

        // In runtime safety modes we have to memset because the Zig allocator
        // interface fills undefined memory with 0xAA. Otherwise, the macOS
        // page allocator returns zeroed pages.
        if (comptime std.debug.runtime_safety)
            @memset(page_buf, 0);

        // Initialize the first set of pages to contain our viewport so that
        // the top of the first page is always the active area.
        node.* = .{
            .data = .{ .resident = .initBuf(.init(page_buf), layout) },
            .serial = serial.*,
            .owned = if (pooled) .pool else .heap,
        };
        node.page().size.rows = @min(rem, node.capacity().rows);
        rem -= node.rows();

        // Add the page to the list
        page_list.append(node);
        page_size += page_buf.len;
        errdefer comptime unreachable;

        // Increment our serial
        serial.* += 1;
    }

    assert(page_list.first != null);

    return .{ page_list, page_size };
}

/// Assert that the PageList is in a valid state. This is a no-op in
/// release builds.
pub inline fn assertIntegrity(self: *const PageList) void {
    if (comptime !build_options.slow_runtime_safety) return;

    self.verifyIntegrity() catch |err| {
        log.err("PageList integrity check failed: {}", .{err});
        @panic("PageList integrity check failed");
    };
}

/// Pause or resume integrity checks. This is useful when you're doing
/// a multi-step operation that temporarily leaves the PageList in an
/// inconsistent state.
pub inline fn pauseIntegrityChecks(self: *PageList, pause: bool) void {
    if (comptime !build_options.slow_runtime_safety) return;
    if (pause) {
        self.pause_integrity_checks += 1;
    } else {
        self.pause_integrity_checks -= 1;
    }
}

const IntegrityError = error{
    MaxLinesExceeded,
    PageSerialInvalid,
    TotalRowsMismatch,
    TrackedPinInvalid,
    ViewportPinOffsetMismatch,
    ViewportPinInsufficientRows,
};

/// Verify the integrity of the PageList. This is expensive and should
/// only be called in debug/test builds.
fn verifyIntegrity(self: *const PageList) IntegrityError!void {
    if (comptime !build_options.slow_runtime_safety) return;
    if (self.pause_integrity_checks > 0) return;

    // Our viewport pin should never be garbage
    assert(!self.viewport_pin.garbage);

    // Grab our total rows
    var actual_total: usize = 0;
    {
        var node_ = self.pages.first;
        while (node_) |node| {
            actual_total += node.rows();
            node_ = node.next;

            // Every live node must belong to the current validity epoch.
            if (node.serial < self.page_serial_epoch) {
                log.warn(
                    "PageList integrity violation: page serial predates epoch serial={} epoch={}",
                    .{ node.serial, self.page_serial_epoch },
                );
                return IntegrityError.PageSerialInvalid;
            }
        }
    }

    // Verify that our cached total_rows matches the actual row count
    if (actual_total != self.total_rows) {
        log.warn(
            "PageList integrity violation: total_rows mismatch cached={} actual={}",
            .{ self.total_rows, actual_total },
        );
        return IntegrityError.TotalRowsMismatch;
    }

    // A line limit may only be exceeded when the oldest page also contains
    // active rows. Complete historical pages are always eligible for pruning.
    if (self.total_rows > self.rows) {
        const history_rows = self.total_rows - self.rows;
        if (history_rows > self.limits.max(.lines) and
            self.pages.first.? != self.getTopLeft(.active).node)
        {
            log.warn(
                "PageList integrity violation: max lines exceeded history={} max={}",
                .{ history_rows, self.limits.max(.lines) },
            );
            return IntegrityError.MaxLinesExceeded;
        }
    }

    // Verify that all our tracked pins point to valid pages.
    for (self.tracked_pins.keys()) |p| {
        if (!self.pinIsValid(p.*)) return error.TrackedPinInvalid;
    }

    if (self.viewport == .pin) {
        // Verify that our viewport pin row offset is correct.
        const actual_offset: usize = offset: {
            var offset: usize = 0;
            var node = self.pages.last;
            while (node) |n| : (node = n.prev) {
                offset += n.rows();
                if (n == self.viewport_pin.node) {
                    offset -= self.viewport_pin.y;
                    break :offset self.total_rows - offset;
                }
            }

            log.warn(
                "PageList integrity violation: viewport pin not in list",
                .{},
            );
            return error.ViewportPinOffsetMismatch;
        };

        if (self.viewport_pin_row_offset) |cached_offset| {
            if (cached_offset != actual_offset) {
                log.warn(
                    "PageList integrity violation: viewport pin offset mismatch cached={} actual={}",
                    .{ cached_offset, actual_offset },
                );
                return error.ViewportPinOffsetMismatch;
            }
        }

        // Ensure our viewport has enough rows.
        const rows = self.total_rows - actual_offset;
        if (rows < self.rows) {
            log.warn(
                "PageList integrity violation: viewport pin rows too small rows={} needed={}",
                .{ rows, self.rows },
            );
            return error.ViewportPinInsufficientRows;
        }
    }
}

/// Release every page in the list during a teardown walk (deinit,
/// reset, or an errdefer unwinding a partially built list): heap-owned
/// pages go back to the page allocator, pool-owned pages back to the
/// page pool, and the nodes back to the node pool's free list.
fn releasePages(pool: *MemoryPool, list: List) void {
    const page_alloc = pool.pages.allocator;
    var it = list.first;
    while (it) |node| {
        it = node.next;
        const page = node.restore(.discard);
        switch (node.owned) {
            .pool => releasePoolPage(pool, page),
            .heap => page_alloc.free(page.memory),
        }
        pool.nodes.destroy(node);
    }
}

/// Release a pool-owned page during a teardown walk. Unlike
/// destroyNodeExt, this does not zero the page: on native, the item goes
/// straight back to the page allocator, and zeroing it first would write
/// the whole page (and fault a decommitted mapping back in) only for it
/// to be unmapped.
fn releasePoolPage(pool: *MemoryPool, page: *const Page) void {
    const item: *align(std.heap.page_size_min) [std_size]u8 =
        @ptrCast(@alignCast(page.memory.ptr));

    pool.pages.release(item);
}

/// Deinit the pagelist, freeing all page memory and the memory pool.
pub fn deinit(self: *PageList) void {
    // Verify integrity before cleanup
    self.assertIntegrity();

    // Always deallocate our hashmap.
    self.tracked_pins.deinit(self.pool.alloc);

    // Release every page and node back to the pools, then free the pools.
    releasePages(&self.pool, self.pages);
    self.pool.deinit();
}

/// Reset the PageList back to an empty state. This is similar to
/// deinit and reinit but it importantly preserves the pointer
/// stability of tracked pins (they're moved to the top-left since
/// all contents are cleared).
///
/// This can't fail because we always retain at least enough allocated
/// memory to fit the active area.
pub fn reset(self: *PageList) void {
    defer self.assertIntegrity();

    // Reset discards all scrollback, so there is nothing left to compress.
    self.page_compression.reset();

    // Begin a new whole-list validity epoch before rebuilding from the pools.
    // Every old reference now has a serial below the epoch and can be rejected
    // in O(1), even if the node pool later reuses its pointer address.
    self.page_serial_epoch = self.page_serial;

    // We need enough pages/nodes to keep our active area. This should
    // never fail since we by definition have allocated a page already
    // that fits our size but I'm not confident to make that assertion.
    const cap = initialCapacity(self.cols);
    assert(cap.rows > 0);

    // The number of pages we need is the number of rows in the active
    // area divided by the row capacity of a page.
    const page_count = std.math.divCeil(
        usize,
        self.rows,
        cap.rows,
    ) catch unreachable;

    // Before resetting our pools we need to release our pages: heap-owned
    // pages go back to the page allocator and pool-owned pages back to
    // the page pool.
    releasePages(&self.pool, self.pages);

    // Reset our pools to free as much memory as possible while retaining
    // the capacity for at least the minimum number of pages we need.
    // The return value is whether memory was reclaimed or not, but in
    // either case the pool is left in a valid state.
    //
    // Retained page pool items are zero (see PagePool), so there is
    // nothing to scrub before initPages reuses them.
    _ = self.pool.pages.reset(.{
        .retain_with_limit = page_count * PagePool.item_size,
    });
    _ = self.pool.nodes.reset(.{
        .retain_with_limit = page_count * NodePool.item_size,
    });

    // Initialize our pages. This should not be able to fail since
    // we retained the capacity for the minimum number of pages we need.
    self.pages, self.page_size = initPages(
        &self.pool,
        &self.page_serial,
        self.cols,
        self.rows,
    ) catch @panic("initPages failed");

    // Our total rows always goes back to the default
    self.total_rows = self.rows;

    // Update all our tracked pins to point to our first page top-left
    // and mark them as garbage, because it got mangled in a way where
    // semantically it really doesn't make sense.
    {
        var it = self.tracked_pins.iterator();
        while (it.next()) |entry| {
            const p: *Pin = entry.key_ptr.*;
            p.node = self.pages.first.?;
            p.x = 0;
            p.y = 0;
            p.garbage = true;
        }

        // Our viewport pin is never garbage
        self.viewport_pin.garbage = false;
    }

    // Move our viewport back to the active area since everything is gone.
    self.viewport = .active;
}

pub const Clone = struct {
    /// The top and bottom (inclusive) points of the region to clone.
    /// The x coordinate is ignored; the full row is always cloned.
    top: point.Point,
    bot: ?point.Point = null,

    // If this is non-null then cloning will attempt to remap the tracked
    // pins into the new cloned area and will keep track of the old to
    // new mapping in this map. If this is null, the cloned pagelist will
    // not retain any previously tracked pins except those required for
    // internal operations.
    //
    // Any pins not present in the map were not remapped.
    tracked_pins: ?*TrackedPinsRemap = null,

    pub const TrackedPinsRemap = std.AutoHashMap(*Pin, *Pin);
};

/// Clone this pagelist from the top to bottom (inclusive).
///
/// The viewport is always moved to the active area.
///
/// The cloned pagelist must contain at least enough rows for the active
/// area. If the region specified has less rows than the active area then
/// rows will be added to the bottom of the region to make up the difference.
pub fn clone(
    self: *const PageList,
    alloc: Allocator,
    opts: Clone,
) !PageList {
    var it = self.pageIterator(
        .right_down,
        opts.top,
        opts.bot,
    );

    // First, count our pages so our preheat is exactly what we need.
    var it_copy = it;
    const page_count: usize = page_count: {
        var count: usize = 0;
        while (it_copy.next()) |_| count += 1;
        break :page_count count;
    };

    // Setup our pool
    var pool: MemoryPool = try .init(
        alloc,
        pageAllocator(),
        page_count,
    );
    errdefer pool.deinit();

    // Create our viewport. In a clone, the viewport always goes
    // to the top.
    const viewport_pin = try pool.pins.create();
    var tracked_pins = try initTrackedPins(pool.alloc, viewport_pin);
    errdefer tracked_pins.deinit(pool.alloc);

    // Our list of pages
    var page_list: List = .{};
    errdefer releasePages(&pool, page_list);

    // Copy our pages
    var page_serial: u64 = 0;
    var total_rows: usize = 0;
    var page_size: usize = 0;
    while (it.next()) |chunk| {
        // Clone the page. We have to use createPageExt here because
        // we don't know if the source page has a standard size.
        const node = try createPageExt(
            &pool,
            .{ .cap = chunk.node.capacity() },
            &page_serial,
            &page_size,
        );

        // Add the page to the list immediately so that the errdefer
        // above releases it if cloning fails.
        page_list.append(node);

        const dst_page = node.page();
        const src_page = chunk.node.page();
        assert(node.capacity().rows >= chunk.end - chunk.start);
        defer dst_page.assertIntegrity();
        dst_page.size.rows = chunk.end - chunk.start;
        dst_page.size.cols = chunk.node.cols();
        try dst_page.cloneFrom(
            src_page,
            chunk.start,
            chunk.end,
        );

        dst_page.dirty = src_page.dirty;

        total_rows += node.rows();

        // Remap our tracked pins by changing the page and
        // offsetting the Y position based on the chunk start.
        if (opts.tracked_pins) |remap| {
            const pin_keys = self.tracked_pins.keys();
            for (pin_keys) |p| {
                // We're only interested in pins that were within the chunk.
                if (p.node != chunk.node or
                    p.y < chunk.start or
                    p.y >= chunk.end) continue;
                const new_p = try pool.pins.create();
                new_p.* = p.*;
                new_p.node = node;
                new_p.y -= chunk.start;
                try remap.putNoClobber(p, new_p);
                try tracked_pins.putNoClobber(pool.alloc, new_p, {});
            }
        }
    }

    // Initialize our viewport pin to point to the first cloned page
    // so it points to valid memory.
    viewport_pin.* = .{ .node = page_list.first.? };

    var result: PageList = .{
        .pool = pool,
        .pages = page_list,
        .page_serial = page_serial,
        .page_serial_epoch = 0,
        .page_size = page_size,
        .limits = self.limits,
        .cols = self.cols,
        .rows = self.rows,
        .total_rows = total_rows,
        .tracked_pins = tracked_pins,
        .viewport = .{ .active = {} },
        .viewport_pin = viewport_pin,
        .viewport_pin_row_offset = null,
    };

    // We always need to have enough rows for our viewport because this is
    // a pagelist invariant that other code relies on.
    if (total_rows < self.rows) {
        const len = self.rows - total_rows;
        for (0..len) |_| {
            _ = try result.grow();

            // Clear the row. This is not very fast but in reality right
            // now we rarely clone less than the active area and if we do
            // the area is by definition very small.
            const last = result.pages.last.?;
            const page = last.page();
            const row = &page.rows.ptr(page.memory)[last.rows() - 1];
            page.clearCells(row, 0, result.cols);
        }

        // Update our total rows to be our row size.
        result.total_rows = result.rows;
    }

    // A clone can copy more history than its inherited line limit.
    result.limits.enforce(&result, .lines);

    result.assertIntegrity();
    return result;
}

/// Resize options
pub const Resize = struct {
    /// The new cols/cells of the screen.
    cols: ?size.CellCountInt = null,
    rows: ?size.CellCountInt = null,

    /// Whether to reflow the text. If this is false then the text will
    /// be truncated if the new size is smaller than the old size.
    reflow: bool = true,

    /// Set this to the current cursor position in the active area. Some
    /// resize/reflow behavior depends on the cursor position.
    cursor: ?Cursor = null,

    /// Whether the resize may pull rows out of scrollback back into the
    /// active area. If false, growing rows always appends blank rows at the
    /// bottom and a column reflow keeps the top of the active area on the
    /// same content, so a line that is fully in scrollback stays there.
    /// A wrapped line with at least one row still in the active area may
    /// still unwrap back into view.
    ///
    /// This should be false for ptys that keep their own screen buffer
    /// without scrollback (e.g. Windows ConPTY), since they can't pull
    /// rows back and would otherwise get out of sync with us.
    pull_scrollback: bool = true,

    pub const Cursor = struct {
        x: size.CellCountInt,
        y: size.CellCountInt,

        /// When set, this pin preserves right-side blank cells up to the cursor
        /// during reflow.
        pin: ?*Pin = null,
    };
};

/// Resize
/// TODO: docs
pub fn resize(self: *PageList, opts: Resize) Allocator.Error!void {
    defer self.assertIntegrity();

    // Resizing forces all nodes to be decompressed today so we need to
    // reschedule compression.
    // TODO(mitchellh): Deferred reflow on non-viewport/non-active pages.
    self.page_compression.reset();
    self.page_compression.markActivity();

    if (comptime std.debug.runtime_safety) {
        // Resize does not work with 0 values, this should be protected
        // upstream
        if (opts.cols) |v| assert(v > 0);
        if (opts.rows) |v| assert(v > 0);
    }

    // Resizing (especially with reflow) can cause our row offset to
    // become invalid. Rather than do something fancy like we do other
    // places and try to update it in place, we just invalidate it because
    // its too easy to get the logic wrong in here.
    self.viewport_pin_row_offset = null;

    if (!opts.reflow) {
        try self.resizeWithoutReflow(opts);
        // Shrinking the active row count turns former active rows into
        // scrollback even without reflow, which can cross the line limit.
        self.limits.enforce(self, .lines);
        return;
    }

    // Recalculate our minimum limits. This allows grow to work properly when
    // increasing beyond the explicit limits to fit the active area.
    const old_limits = self.limits;
    self.limits.resize(
        opts.cols orelse self.cols,
        opts.rows orelse self.rows,
    );
    errdefer self.limits = old_limits;

    // On reflow, the main thing that causes reflow is column changes. If
    // only rows change, reflow is impossible. So we change our behavior based
    // on the change of columns.
    const cols = opts.cols orelse self.cols;
    switch (std.math.order(cols, self.cols)) {
        .eq => try self.resizeWithoutReflow(opts),

        .gt => {
            // We grow rows after cols so that we can do our unwrapping/reflow
            // before we do a no-reflow grow.
            try self.resizeCols(cols, opts);
            try self.resizeWithoutReflow(opts);
        },

        .lt => {
            // We first change our row count so that we have the proper amount
            // we can use when shrinking our cols.
            try self.resizeWithoutReflow(opts: {
                var copy = opts;
                copy.cols = self.cols;
                break :opts copy;
            });
            try self.resizeCols(cols, opts);
        },
    }

    // Various resize operations can change our total row count such
    // that our viewport pin is now in the active area and has insufficient
    // space. We need to check for this case and fix it up.
    switch (self.viewport) {
        .pin => if (self.pinIsActive(self.viewport_pin.*)) {
            self.viewport = .active;
        },
        .active, .top => {},
    }

    // Column reflow can change the physical history row count, and a row
    // resize can move the active boundary. Both may expose whole old pages
    // that are now eligible for line-limit pruning.
    self.limits.enforce(self, .lines);
}

/// Resize the pagelist with reflow by adding or removing columns.
fn resizeCols(
    self: *PageList,
    cols: size.CellCountInt,
    opts: Resize,
) Allocator.Error!void {
    assert(cols != self.cols);
    const cursor = opts.cursor;

    // The active area is always the last `rows` rows, so a reflow that
    // changes the number of rows our text needs slides the active area
    // over the content. If we aren't allowed to pull scrollback then we
    // track the top of the active area so we can restore it afterwards.
    const active_top: ?*Pin = if (!opts.pull_scrollback)
        try self.trackPin(self.getTopLeft(.active))
    else
        null;
    defer if (active_top) |p| self.untrackPin(p);

    // If we have a cursor position (x,y), then we try under any col resizing
    // to keep the same number remaining active rows beneath it. This is a
    // very special case if you can imagine clearing the screen (i.e.
    // scrollClear), having an empty active area, and then resizing to less
    // cols then we don't want the active area to "jump" to the bottom and
    // pull down scrollback.
    const preserved_cursor: ?struct {
        tracked_pin: *Pin,
        untrack: bool,
        remaining_rows: usize,
        wrapped_rows: usize,
    } = if (cursor) |c| cursor: {
        const p = if (c.pin) |cursor_pin| cursor_pin.* else self.pin(.{ .active = .{
            .x = c.x,
            .y = c.y,
        } }) orelse break :cursor null;

        const active_pin = self.pin(.{ .active = .{} });

        // We count how many wraps the cursor had before it to begin with
        // so that we can offset any additional wraps to avoid pushing the
        // original row contents in to the scrollback.
        const wrapped = wrapped: {
            var wrapped: usize = 0;

            // If shrinking rows (in the .lt branch of resize, rows shrink
            // before we get here) pushed the cursor pin above the new active
            // area, there are no rows to count and iterating .left_up toward
            // the active-area top would be an invalid (reversed) range. The
            // preserved-cursor growth below already no-ops for a cursor that
            // isn't in the active area, so we just count zero here.
            if (active_pin) |ap| {
                if (p.before(ap)) break :wrapped 0;
            }

            var row_it = p.rowIterator(.left_up, active_pin);
            while (row_it.next()) |next| {
                const row = next.rowAndCell().row;
                if (row.wrap_continuation) wrapped += 1;
            }

            break :wrapped wrapped;
        };

        break :cursor .{
            .tracked_pin = c.pin orelse try self.trackPin(p),
            .untrack = c.pin == null,
            .remaining_rows = self.rows -| (c.y + 1),
            .wrapped_rows = wrapped,
        };
    } else null;
    defer if (preserved_cursor) |c| {
        if (c.untrack) self.untrackPin(c.tracked_pin);
    };

    // Update our cols. We have to do this early because grow() that we
    // may call below relies on this to calculate the proper page size, but
    // after preserved_cursor so that the cursor pin can resolve coordinates in
    // the old active coordinate space.
    self.cols = cols;

    // Create the first node that contains our reflow.
    const first_rewritten_node = node: {
        const page = self.pages.first.?.page();
        const cap = page.capacity.adjust(
            .{ .cols = cols },
        ) catch |err| err: {
            comptime assert(@TypeOf(err) == error{OutOfMemory});

            // We verify all maxed out page layouts work.
            var cap = page.capacity;
            cap.cols = cols;

            // We're growing columns so we can only get less rows so use
            // the lesser of our capacity and size so we minimize wasted
            // rows.
            cap.rows = @min(page.size.rows, cap.rows);
            break :err cap;
        };

        const node = try self.createPage(.{ .cap = cap });
        node.page().size.rows = 1;
        break :node node;
    };

    // We need to grab our rowIterator now before we rewrite our
    // linked list below.
    var it = self.rowIterator(
        .right_down,
        .{ .screen = .{} },
        null,
    );
    errdefer {
        // If an error occurs, we're in a pretty disastrous broken state,
        // but we should still try to clean up our leaked memory. Free
        // any of the remaining orphaned pages from before. If we reflowed
        // successfully this will be null.
        var node_: ?*Node = if (it.chunk) |chunk| chunk.node else null;
        while (node_) |node| {
            node_ = node.next;
            self.destroyNode(node);
        }
    }

    // Reflowed source pages are stashed for reuse as destination
    // pages (see recycle_node). Whether we succeed or fail, a stashed
    // node must not outlive the reflow.
    defer if (self.recycle_node) |node| {
        self.recycle_node = null;
        self.destroyNode(node);
    };

    // Set our new page as the only page. This orphans the existing pages
    // in the list, but that's fine since we're gonna delete them anyway.
    self.pages.first = first_rewritten_node;
    self.pages.last = first_rewritten_node;

    // Reflow all our rows.
    {
        var reflow_cursor: ReflowCursor = .init(first_rewritten_node);
        while (it.next()) |row| {
            try reflow_cursor.reflowRow(
                self,
                row,
                if (preserved_cursor) |c| c.tracked_pin else null,
            );

            // Once we're done reflowing a page, we're done with it, so
            // make it available for reuse (or destroy it). Making it
            // immediately available frees memory and makes it more
            // likely in memory constrained environments that the next
            // reflow will work.
            if (row.y == row.node.rows() - 1) destroy_node: {
                if (self.recycle_node != null or
                    row.node.owned != .pool or
                    row.node.data != .resident)
                {
                    self.destroyNode(row.node);
                    break :destroy_node;
                }

                self.recycle_node = row.node;
            }
        }

        // At the end of the reflow, setup our total row cache
        // log.warn("total old={} new={}", .{ self.total_rows, reflow_cursor.total_rows });
        self.total_rows = reflow_cursor.total_rows;
    }

    // If our total rows is less than our active rows, we need to grow.
    // This can happen if you're growing columns such that enough active
    // rows unwrap that we no longer have enough.
    var node_it = self.pages.first;
    var total: usize = 0;
    while (node_it) |node| : (node_it = node.next) {
        total += node.rows();
        if (total >= self.rows) break;
    } else {
        for (total..self.rows) |_| _ = try self.grow();
    }

    // Reflow can unwrap enough rows that a history viewport pin lands in the
    // active area before we do any preserved-cursor growth below. Switch back
    // to the active viewport now so intermediate grow() integrity checks stay
    // valid.
    switch (self.viewport) {
        .active, .top => {},
        .pin => if (self.pinIsActive(self.viewport_pin.*)) {
            self.viewport = .active;
        },
    }

    // If we can't pull scrollback then pad the bottom with blank rows until
    // the old top of the active area is back at the top. If the reflow
    // instead pushed it into scrollback (the text needs more rows than
    // we have) then there is nothing to do. This subsumes the preserved
    // cursor logic below since that also only exists to avoid a pull.
    if (active_top) |p| {
        if (self.pointFromPin(.active, p.*)) |pt| {
            for (0..pt.active.y) |_| _ = try self.grow();
        }
        return;
    }

    // See preserved_cursor setup for why.
    if (preserved_cursor) |c| cursor: {
        const active_pt = self.pointFromPin(
            .active,
            c.tracked_pin.*,
        ) orelse break :cursor;

        const active_pin = self.pin(.{ .active = .{} });

        // We need to determine how many rows we wrapped from the original
        // and subtract that from the remaining rows we expect because if
        // we wrap down we don't want to push our original row contents into
        // the scrollback.
        const wrapped = wrapped: {
            var wrapped: usize = 0;

            var row_it = c.tracked_pin.rowIterator(.left_up, active_pin);
            while (row_it.next()) |next| {
                const row = next.rowAndCell().row;
                if (row.wrap_continuation) wrapped += 1;
            }

            break :wrapped wrapped;
        };

        const current = self.rows -| (active_pt.active.y + 1);

        var req_rows = c.remaining_rows;
        req_rows -|= wrapped -| c.wrapped_rows;
        req_rows -|= current;

        while (req_rows > 0) {
            _ = try self.grow();
            req_rows -= 1;
        }
    }
}

// We use a cursor to track where we are in the src/dst. This is very
// similar to Screen.Cursor, so see that for docs on individual fields.
// We don't use a Screen because we don't need all the same data and we
// do our best to optimize having direct access to the page memory.
const ReflowCursor = struct {
    x: size.CellCountInt,
    y: size.CellCountInt,
    pending_wrap: bool,
    node: *List.Node,
    page: *pagepkg.Page,
    page_row: *pagepkg.Row,
    page_cell: *pagepkg.Cell,
    new_rows: usize,

    /// This is the final row count of the reflowed pages.
    total_rows: usize,

    /// Memoizes the most recent source-to-destination style id
    /// mapping. Styled cells come in long runs sharing the same style
    /// so this lets writeCell bump the destination ref count directly
    /// instead of performing a set lookup for every styled cell.
    ///
    /// The destination id is only valid for the current destination
    /// page, which is why this lives on the cursor: every destination
    /// page change goes through init() which resets this.
    style_cache: StyleCache,

    /// Memoizes the capacity adjustment for new destination pages
    /// (see reflowRow). It only depends on the source page so this is
    /// keyed by the source page pointer, which reflow visits
    /// sequentially and never revisits.
    cap_memo: ?struct {
        src_page: *const Page,
        cap: Capacity,
    },

    const StyleCache = struct {
        src_page: ?*const Page,
        src_id: stylepkg.Id,
        dst_id: stylepkg.Id,

        const invalid: StyleCache = .{
            .src_page = null,
            .src_id = stylepkg.default_id,
            .dst_id = stylepkg.default_id,
        };
    };

    fn init(node: *List.Node) ReflowCursor {
        const page = node.page();
        const rows = page.rows.ptr(page.memory);
        return .{
            .x = 0,
            .y = 0,
            .pending_wrap = false,
            .node = node,
            .page = page,
            .page_row = &rows[0],
            .page_cell = &rows[0].cells.ptr(page.memory)[0],
            .new_rows = 0,

            // Initially whatever size our input node is.
            .total_rows = node.rows(),

            .style_cache = .invalid,
            .cap_memo = null,
        };
    }

    /// Reflow the provided row in to this cursor.
    fn reflowRow(
        self: *ReflowCursor,
        list: *PageList,
        row: Pin,
        cursor_pin: ?*Pin,
    ) Allocator.Error!void {
        const src_page: *Page = row.node.page();
        const src_row = row.rowAndCell().row;
        const src_y = row.y;
        const cells = src_row.cells.ptr(src_page.memory)[0..src_page.size.cols];

        // Calculate the columns in this row. First up we trim non-semantic
        // rightmost blanks.
        var cols_len = src_page.size.cols;
        if (!src_row.wrap) {
            while (cols_len > 0) {
                if (!cells[cols_len - 1].isEmpty()) break;
                cols_len -= 1;
            }

            // If the row has a semantic prompt then the blank row is meaningful
            // so we just consider pretend the first cell of the row isn't empty.
            if (cols_len == 0 and src_row.semantic_prompt != .none) cols_len = 1;
        }

        // Handle tracked pin adjustments. We also note whether any
        // tracked pin is on this row at all so that the per-cell loop
        // below can skip pin scans entirely for the overwhelmingly
        // common case of a row with no pins. Note we compare nodes
        // rather than pages since a node owns exactly one page; this
        // is cheaper and avoids `page()` restoring unrelated
        // compressed nodes purely for a comparison.
        var row_has_pins = false;
        {
            const pin_keys = list.tracked_pins.keys();
            for (pin_keys) |p| {
                if (p.node != row.node or p.y != src_y) continue;

                // This row has pins
                row_has_pins = true;

                if (cursor_pin != null and p == cursor_pin.?) continue;

                // If this pin is in the blanks on the right and past the end
                // of the dst col width then we move it to the end of the dst
                // col width instead.
                if (p.x >= cols_len) p.x = @min(
                    p.x,
                    self.page.size.cols - 1 - self.x,
                );

                // We increase our col len to at least include this pin.
                // This ensures that blank rows with pins are processed,
                // so that the pins can be properly remapped.
                cols_len = @max(cols_len, p.x + 1);
            }
        }

        // If the cursor is after blanks on the right, those cells are still
        // before the next write and must reflow with it.
        if (cursor_pin) |p| {
            if (p.node == row.node and p.y == src_y) {
                cols_len = @max(cols_len, p.x + 1);
            }
        }

        // Defer processing of blank rows so that blank rows
        // at the end of the page list are never written.
        if (cols_len == 0) {
            // If this blank row was a wrap continuation somehow
            // then we won't need to write it since it should be
            // a part of the previously written row.
            if (!src_row.wrap_continuation) self.new_rows += 1;
            return;
        }

        // Inherit increased styles or grapheme bytes from the src page
        // we're reflowing from for new pages.
        //
        // This only depends on the source page, which we process row
        // by row, so memoize it: computing the adjustment requires a
        // full page layout calculation which is much too expensive to
        // do for every row.
        const cap: Capacity = if (self.cap_memo) |memo| cap: {
            if (memo.src_page == src_page) break :cap memo.cap;
            // Source page changed, fall through to recompute.
            break :cap self.computeAndMemoizeCap(src_page);
        } else self.computeAndMemoizeCap(src_page);

        // Our row isn't blank, write any new rows we deferred.
        while (self.new_rows > 0) {
            try self.cursorScrollOrNewPage(list, cap);
            self.new_rows -= 1;
        }

        self.copyRowMetadata(src_row);

        var x: usize = 0;
        while (x < cols_len) {
            if (self.pending_wrap) {
                self.page_row.wrap = true;
                try self.cursorScrollOrNewPage(list, cap);
                self.copyRowMetadata(src_row);
                self.page_row.wrap_continuation = true;
            }

            // Fast path: bulk-copy a run of simple cells directly
            // into the destination row. The vast majority of cells
            // are narrow cells or complete wide pairs, have no
            // managed memory (graphemes, hyperlinks), and share a
            // single style in long runs, so this avoids the
            // per-cell state machine below for most of the work.
            // Rows with tracked pins take the slow path so pin
            // remapping behaves identically.
            if (!row_has_pins) {
                const max_run = @min(
                    cols_len - x,
                    @as(usize, self.page.size.cols) - self.x,
                );
                const window = cells[x..][0..max_run];
                const run = bulkRunLength(window);
                if (run > 0 and self.copyRun(window[0..run], src_page)) {
                    x += run;
                    continue;
                }
            }

            // Move any tracked pins from the source.
            if (row_has_pins) {
                const pin_keys = list.tracked_pins.keys();
                for (pin_keys) |p| {
                    if (p.node != row.node or
                        p.y != src_y or
                        p.x != x) continue;

                    p.node = self.node;
                    p.x = self.x;
                    p.y = self.y;
                }
            }

            if (self.writeCell(
                list,
                &cells[x],
                src_page,
            )) |result| switch (result) {
                // Wrote the cell, move to the next.
                .success => x += 1,

                // Wrote the cell but request to skip the next so skip it.
                // This is used for things like spacers.
                .skip_next => {
                    // Remap any tracked pins at the skipped position (x+1)
                    // since we won't process that cell in the loop.
                    if (row_has_pins) for (list.tracked_pins.keys()) |p| {
                        if (p.node != row.node or
                            p.y != src_y or
                            p.x != x + 1) continue;

                        p.node = self.node;
                        p.x = self.x;
                        p.y = self.y;
                    };

                    x += 2;
                },

                // Didn't write the cell, repeat writing this same cell.
                .repeat => {},
            } else |err| switch (err) {
                // System out of memory, we can't fix this.
                error.OutOfMemory => return error.OutOfMemory,

                // We reached the capacity of a single page and can't
                // add any more of some type of managed memory. When this
                // happens we split out the current row we're working on
                // into a new page and continue from there.
                error.OutOfSpace => if (self.y == 0) {
                    // If we're already on the first-row, we can't split
                    // any further, so we just ignore bad cells and take
                    // corrupted (but valid) cell contents.
                    log.warn("reflowRow OutOfSpace on first row, discarding cell managed memory", .{});
                    x += 1;
                    self.cursorForward();
                } else {
                    // Move our last row to a new page.
                    try self.moveLastRowToNewPage(list, cap);

                    // Do NOT increment x so that we retry writing
                    // the same existing cell.
                },
            }
        }

        // If the source row isn't wrapped then we should scroll afterwards.
        if (!src_row.wrap) {
            self.new_rows += 1;
        }
    }

    /// Compute and memoize the new-page capacity for the given source
    /// page. See the call site in reflowRow for details.
    fn computeAndMemoizeCap(
        self: *ReflowCursor,
        src_page: *const Page,
    ) Capacity {
        const cap = src_page.capacity.adjust(
            .{ .cols = self.page.size.cols },
        ) catch |err| err: {
            comptime assert(@TypeOf(err) == error{OutOfMemory});

            var cap = src_page.capacity;
            cap.cols = self.page.size.cols;
            // We're already a non-standard page. We don't want to
            // inherit a massive set of rows, so cap it at our std size.
            cap.rows = @min(src_page.size.rows, std_capacity.rows);
            break :err cap;
        };

        self.cap_memo = .{ .src_page = src_page, .cap = cap };
        return cap;
    }

    /// True if this cell can be copied verbatim as part of a bulk
    /// run: a narrow plain-text or bg-color cell with no managed
    /// memory (graphemes, hyperlinks) and no special reflow handling
    /// (wide characters, spacers, Kitty virtual placeholders). For
    /// these cells writeCell reduces to a copy of the raw cell plus
    /// a style ref count adjustment.
    inline fn bulkCopyable(cell: pagepkg.Cell) bool {
        return switch (cell.content_tag) {
            .codepoint => copyable: {
                if (cell.wide != .narrow) break :copyable false;
                if (cell.hyperlink) break :copyable false;
                {
                    // Placeholders must set a row flag, so they take
                    // the slow path.
                    if (cell.content.codepoint.data ==
                        kitty.graphics.unicode.placeholder)
                    {
                        break :copyable false;
                    }
                }
                break :copyable true;
            },

            // Grapheme data must be cloned cell-by-cell.
            .codepoint_grapheme => false,

            // These are guaranteed to have no style or grapheme data
            // (see writeCell) so they are pure copies. The style
            // check is defensive so that a bg cell can never join or
            // extend a styled run.
            .bg_color_palette,
            .bg_color_rgb,
            => cell.style_id == stylepkg.default_id,
        };
    }

    /// The group length for the vectorized bulk run scan below: the
    /// SIMD lane count where the target supports it, otherwise a
    /// plain unrolled group like other cell scans use (e.g. the
    /// render state scans).
    const bulk_group_len = simd.lanes(u64) orelse 8;

    /// Masked compare helper covering every cell field that a run
    /// must share to be copied by copyRun: given that the first cell
    /// of a run passed the full bulkCopyable predicate, equality on
    /// these fields implies the same for every subsequent cell, with
    /// the same style.
    ///
    /// Note this is slightly stricter than bulkCopyable (e.g. a
    /// bg-color cell won't extend an unstyled text run even though it
    /// is copyable): that only splits the copy into multiple runs,
    /// which is still correct.
    const BulkRunMask = pagepkg.Mask(pagepkg.Cell, &.{
        "content_tag",
        "style_id",
        "wide",
        "hyperlink",
    }, bulk_group_len);

    /// Masked compare helper for detecting the Kitty virtual
    /// placeholder codepoint in text cells. Placeholders take the
    /// slow path (they must set a row flag), so they terminate a run.
    const PlaceholderMask = pagepkg.Mask(pagepkg.Cell, &.{
        "content.codepoint.data",
    }, bulk_group_len);

    /// The length of the prefix of cells that can be copied at once
    /// with copyRun: bulk-copyable cells sharing a single style. The
    /// scan uses masked compares of the raw cell bits (see
    /// BulkRunMask), which is significantly cheaper than the
    /// field-wise predicate for this hot loop.
    fn bulkRunLength(cells: []const pagepkg.Cell) usize {
        if (cells.len == 0) return 0;
        const first = cells[0];

        // A run may start on a bulk-copyable narrow cell or on a wide pair.
        const pair_start = first.content_tag == .codepoint and
            first.wide == .wide and
            !first.hyperlink;
        if (!pair_start and !bulkCopyable(first)) return 0;

        // Patterns for each cell shape admitted to the run.
        var proto = first;
        proto.wide = .narrow;
        const narrow_pattern = BulkRunMask.pattern(proto);
        proto.wide = .wide;
        const wide_pattern = BulkRunMask.pattern(proto);
        proto.wide = .spacer_tail;
        const tail_pattern = BulkRunMask.pattern(proto);

        // Only text cells can contain a placeholder; for bg color
        // tags the content bits are a color, so we skip the check for
        // those (the tag is part of BulkRunMask, making tags uniform
        // per run).
        const check_placeholder = first.content_tag == .codepoint;
        const placeholder_pattern = comptime pattern: {
            // Never used without kitty graphics (check_placeholder
            // is comptime-false), but it must still compile and the
            // placeholder codepoint doesn't exist in that build.

            break :pattern PlaceholderMask.pattern(.init(
                kitty.graphics.unicode.placeholder,
            ));
        };

        var len: usize = 0;
        outer: while (true) {
            // Vectorized scan: check whole groups of narrow cells at
            // once. If a group fully matches, the run extends by the
            // whole group; otherwise fall through to the scalar loop
            // below, which finds the exact end of the run within it
            // or continues through a wide pair.
            while (cells.len - len >= bulk_group_len) {
                if (!BulkRunMask.eql(cells, len, narrow_pattern)) break;
                if (check_placeholder and PlaceholderMask.eqlAny(
                    cells,
                    len,
                    placeholder_pattern,
                )) break;
                len += bulk_group_len;
            }

            while (len < cells.len) {
                const cell = cells[len];
                if (BulkRunMask.eqlScalar(cell, narrow_pattern)) {
                    if (check_placeholder and PlaceholderMask.eqlScalar(
                        cell,
                        placeholder_pattern,
                    )) break :outer;
                    len += 1;
                    continue;
                }

                // Wide pairs are consumed atomically so the run
                // (or window) end can never split a pair.
                if (len + 1 < cells.len and
                    BulkRunMask.eqlScalar(cell, wide_pattern) and
                    BulkRunMask.eqlScalar(cells[len + 1], tail_pattern))
                {
                    len += 2;
                    // Re-enter the vectorized loop: narrow groups
                    // commonly follow a stretch of pairs.
                    continue :outer;
                }

                break :outer;
            }

            break;
        }

        return len;
    }

    /// Copy a run of bulk-copyable cells (see bulkCopyable) sharing
    /// one style into the destination row at the current position,
    /// then advance the cursor. The run must fit in the remaining
    /// columns of the destination row.
    ///
    /// Returns false without any state change if the style could not
    /// be mapped into the destination page without a capacity
    /// change; the caller should fall back to writeCell which
    /// handles growing capacity.
    fn copyRun(
        self: *ReflowCursor,
        src_cells: []const pagepkg.Cell,
        src_page: *const Page,
    ) bool {
        assert(!self.pending_wrap);
        assert(src_cells.len >= 1);
        assert(src_cells.len <= self.page.size.cols - self.x);

        const style_id = src_cells[0].style_id;
        const n: u16 = @intCast(src_cells.len);

        // Resolve the destination style id for this run and take one
        // reference per cell. This mirrors the per-cell style logic
        // in writeCell, including the memoization (see StyleCache).
        const dst_style_id: stylepkg.Id = if (style_id == stylepkg.default_id)
            stylepkg.default_id
        else dst: {
            if (self.style_cache.src_page == @as(?*const Page, src_page) and
                self.style_cache.src_id == style_id)
            {
                const id = self.style_cache.dst_id;
                self.page.styles.useMultiple(self.page.memory, id, n);
                break :dst id;
            }

            const style = src_page.styles.get(
                src_page.memory,
                style_id,
            ).*;

            // Any error here (set full or needs rehash) is handled
            // by falling back to the slow path, which grows capacity.
            // No state has been modified yet at this point.
            const id = (self.page.styles.addWithId(
                self.page.memory,
                style,
                style_id,
            ) catch return false) orelse style_id;

            // addWithId took one reference, take the rest.
            if (n > 1) self.page.styles.useMultiple(
                self.page.memory,
                id,
                n - 1,
            );

            self.style_cache = .{
                .src_page = src_page,
                .src_id = style_id,
                .dst_id = id,
            };

            break :dst id;
        };

        // Copy the raw cell contents.
        const dst_cells: []pagepkg.Cell = @as(
            [*]pagepkg.Cell,
            @ptrCast(self.page_cell),
        )[0..src_cells.len];
        @memcpy(dst_cells, src_cells);

        // If the style resolved to a different id in the destination
        // page then rewrite the copied cells to point at it.
        if (dst_style_id != style_id) {
            for (dst_cells) |*cell| cell.style_id = dst_style_id;
        }
        if (dst_style_id != stylepkg.default_id) self.page_row.styled = true;

        // Advance the cursor, matching what repeated cursorForward
        // calls after each cell write would have done.
        const cols = self.page.size.cols;
        const cell_ptr: [*]pagepkg.Cell = @ptrCast(self.page_cell);
        if (self.x + n == cols) {
            self.x = cols - 1;
            self.page_cell = @ptrCast(cell_ptr + n - 1);
            self.pending_wrap = true;
        } else {
            self.x += n;
            self.page_cell = @ptrCast(cell_ptr + n);
        }

        return true;
    }

    /// Write a cell. On error, this will not unwrite the cell but
    /// the cell may be incomplete (but valid). For example, if the source
    /// cell is styled and we failed to allocate space for styles, the
    /// written cell may not be styled but it is valid.
    ///
    /// The key failure to recognize for callers is when we can't increase
    /// capacity in our destination page. In this case, the caller may want
    /// to split the page at this row, rewrite the row into a new page
    /// and continue from there.
    ///
    /// But this function guarantees the terminal/page will be in a
    /// coherent state even on error.
    fn writeCell(
        self: *ReflowCursor,
        list: *PageList,
        cell: *const pagepkg.Cell,
        src_page: *const Page,
    ) IncreaseCapacityError!enum {
        success,
        repeat,
        skip_next,
    } {
        // Initialize self.page_cell with basic, unmanaged memory contents.
        {
            // This must not fail because we want to make sure we atomically
            // setup our page cell to be valid.
            errdefer comptime unreachable;

            // Copy cell contents.
            switch (cell.content_tag) {
                .codepoint,
                .codepoint_grapheme,
                => switch (cell.wide) {
                    .narrow => self.page_cell.* = cell.*,

                    .wide => if (self.page.size.cols > 1) {
                        if (self.x == self.page.size.cols - 1) {
                            // If there's a wide character in the last column of
                            // the reflowed page then we need to insert a spacer
                            // head and wrap before handling it.
                            self.page_cell.* = .{
                                .content_tag = .codepoint,
                                .content = .{ .codepoint = .{ .data = 0 } },
                                .wide = .spacer_head,
                            };

                            // Move to the next row (this sets pending wrap
                            // which will cause us to wrap on the next
                            // iteration).
                            self.cursorForward();

                            // Decrement the source position so that when we
                            // loop we'll process this source cell again,
                            // since we can't copy it into a spacer head.
                            return .repeat;
                        } else {
                            self.page_cell.* = cell.*;
                        }
                    } else {
                        // Edge case, when resizing to 1 column, wide
                        // characters are just destroyed and replaced
                        // with empty narrow cells.
                        self.page_cell.content.codepoint = .{ .data = 0 };
                        self.page_cell.wide = .narrow;
                        self.cursorForward();

                        // Skip spacer tail so it doesn't cause a wrap.
                        return .skip_next;
                    },

                    .spacer_tail => if (self.page.size.cols > 1) {
                        self.page_cell.* = cell.*;
                    } else {
                        // Edge case, when resizing to 1 column, wide
                        // characters are just destroyed and replaced
                        // with empty narrow cells, so we should just
                        // discard any spacer tails.
                        return .success;
                    },

                    .spacer_head => {
                        // Spacer heads should be ignored. If we need a
                        // spacer head in our reflowed page, it is added
                        // when processing the wide cell it belongs to.
                        return .success;
                    },
                },

                .bg_color_palette,
                .bg_color_rgb,
                => {
                    // These are guaranteed to have no style or grapheme
                    // data associated with them so we can fast path them.
                    self.page_cell.* = cell.*;
                    self.cursorForward();
                    return .success;
                },
            }

            // These will create issues by trying to clone managed memory that
            // isn't set if the current dst row needs to be moved to a new page.
            // They'll be fixed once we do properly copy the relevant memory.
            self.page_cell.content_tag = .codepoint;
            self.page_cell.hyperlink = false;
            self.page_cell.style_id = stylepkg.default_id;

            {
                // Copy Kitty virtual placeholder status
                if (cell.codepoint() == kitty.graphics.unicode.placeholder) {
                    self.page_row.kitty_virtual_placeholder = true;
                }
            }
        }

        // std.log.warn("\nsrc_y={} src_x={} dst_y={} dst_x={} dst_cols={} cp={X} wide={} page_cell_wide={}", .{
        //     src_y,
        //     x,
        //     self.y,
        //     self.x,
        //     self.page.size.cols,
        //     cell.content.codepoint,
        //     cell.wide,
        //     self.page_cell.wide,
        // });

        // From this point on we're moving on to failable, managed memory.
        // If we reach an error, we do the minimal cleanup necessary to
        // not leave dangling memory but otherwise we gracefully degrade
        // into some functional but not strictly correct cell.

        // Copy grapheme data.
        if (cell.content_tag == .codepoint_grapheme) {
            // Copy the graphemes
            const cps = src_page.lookupGrapheme(cell).?;

            // If our page can't support an additional cell
            // with graphemes then we increase capacity.
            if (self.page.graphemeCount() >= self.page.graphemeCapacity()) {
                try self.increaseCapacity(
                    list,
                    .grapheme_bytes,
                );
            }

            // Attempt to allocate the space that would be required
            // for these graphemes, and if it's not available, then
            // increase capacity. Keep trying until we succeed.
            while (true) {
                if (self.page.grapheme_alloc.alloc(
                    u21,
                    self.page.memory,
                    cps.len,
                )) |slice| {
                    self.page.grapheme_alloc.free(
                        self.page.memory,
                        slice,
                    );
                    break;
                } else |_| {
                    // Grow our capacity until we can fit the extra bytes.
                    try self.increaseCapacity(list, .grapheme_bytes);
                }
            }

            self.page.setGraphemes(
                self.page_row,
                self.page_cell,
                cps,
            ) catch |err| {
                // This shouldn't fail since we made sure we have space
                // above. There is no reasonable behavior we can take here
                // so we have a warn level log. This is ALMOST non-recoverable,
                // though we choose to recover by corrupting the cell
                // to a non-grapheme codepoint.
                log.err("setGraphemes failed after capacity increase err={}", .{err});
                if (comptime std.debug.runtime_safety) {
                    // Force a crash with safe builds.
                    unreachable;
                }

                // Unsafe builds we throw away grapheme data!
                self.page_cell.content_tag = .codepoint;
                self.page_cell.content = .{ .codepoint = .{ .data = 0xFFFD } };
            };
        }

        // Copy hyperlink data.
        if (cell.hyperlink) hyperlink: {
            const src_id = src_page.lookupHyperlink(cell).?;
            const src_link = src_page.hyperlink_set.get(src_page.memory, src_id);

            // If our page can't support an additional cell
            // with a hyperlink then we increase capacity.
            if (self.page.hyperlinkCount() >= self.page.hyperlinkCapacity()) {
                try self.increaseCapacity(list, .hyperlink_bytes);
            }

            // Ensure that the string alloc has sufficient capacity
            // to dupe the link (and the ID if it's not implicit).
            // Grow our capacity until the hyperlink fits.
            while (!self.hyperlinkStringsFit(src_link)) {
                try self.increaseCapacity(list, .string_bytes);
            }

            const dst_link = src_link.dupe(
                src_page,
                self.page,
            ) catch |err| {
                // This shouldn't fail since we did a capacity
                // check above.
                log.err("link dupe failed with capacity check err={}", .{err});
                if (comptime std.debug.runtime_safety) {
                    // Force a crash with safe builds.
                    unreachable;
                }

                break :hyperlink;
            };

            const dst_id = self.page.hyperlink_set.addWithIdContext(
                self.page.memory,
                dst_link,
                src_id,
                .{ .page = self.page },
            ) catch |err| id: {
                // Always free our original link in case the increaseCap
                // call fails so we aren't leaking memory.
                dst_link.free(self.page);

                // If the add failed then either the set needs to grow
                // or it needs to be rehashed. Either one of those can
                // be accomplished by increasing capacity, either with
                // no actual change or with an increased hyperlink cap.
                try self.increaseCapacity(list, switch (err) {
                    error.OutOfMemory => .hyperlink_bytes,
                    error.NeedsRehash => null,
                });

                // The increaseCapacity call above swapped self.page
                // for a new page, so the string capacity check done
                // before the first dupe no longer applies. Re-establish
                // it against the current page before duping again.
                while (!self.hyperlinkStringsFit(src_link)) {
                    try self.increaseCapacity(list, .string_bytes);
                }

                // We need to recreate the link into the new page.
                const dst_link2 = src_link.dupe(
                    src_page,
                    self.page,
                ) catch |err2| {
                    // This shouldn't fail since we did a capacity
                    // check above.
                    log.err("link dupe failed with capacity check err={}", .{err2});
                    if (comptime std.debug.runtime_safety) {
                        // Force a crash with safe builds.
                        unreachable;
                    }

                    break :hyperlink;
                };

                // We assume this one will succeed. We dupe the link
                // again, and don't have to worry about the other one
                // because increasing the capacity naturally clears up
                // any managed memory not associated with a cell yet.
                break :id self.page.hyperlink_set.addWithIdContext(
                    self.page.memory,
                    dst_link2,
                    src_id,
                    .{ .page = self.page },
                ) catch |err2| {
                    // This shouldn't happen since we increased capacity
                    // above so we handle it like the other similar
                    // cases and log it, crash in safe builds, and
                    // remove the hyperlink in unsafe builds.
                    log.err(
                        "addWithIdContext failed after capacity increase err={}",
                        .{err2},
                    );
                    if (comptime std.debug.runtime_safety) {
                        // Force a crash with safe builds.
                        unreachable;
                    }

                    dst_link2.free(self.page);
                    break :hyperlink;
                };
            } orelse src_id;

            // We expect this to succeed due to the hyperlinkCapacity
            // check we did before. If it doesn't succeed let's
            // log it, crash (in safe builds), and clear our state.
            self.page.setHyperlink(
                self.page_row,
                self.page_cell,
                dst_id,
            ) catch |err| {
                log.err(
                    "setHyperlink failed after capacity increase err={}",
                    .{err},
                );
                if (comptime std.debug.runtime_safety) {
                    // Force a crash with safe builds.
                    unreachable;
                }

                // Unsafe builds we throw away hyperlink data!
                self.page.hyperlink_set.release(self.page.memory, dst_id);
                self.page_cell.hyperlink = false;
                break :hyperlink;
            };
        }

        // Copy style data.
        if (cell.hasStyling()) style: {
            // Fast path: styled cells come in long runs sharing the
            // same style. If this source style was just mapped into
            // the current destination page, bump the ref count
            // directly and skip the set lookup. The destination id is
            // guaranteed alive because a previously written cell in
            // this page holds a reference, and the cache is reset
            // whenever the destination page changes (see init).
            if (self.style_cache.src_page == src_page and
                self.style_cache.src_id == cell.style_id)
            {
                const id = self.style_cache.dst_id;
                self.page.styles.use(self.page.memory, id);
                self.page_row.styled = true;
                self.page_cell.style_id = id;
                break :style;
            }

            const style = src_page.styles.get(
                src_page.memory,
                cell.style_id,
            ).*;

            const id = self.page.styles.addWithId(
                self.page.memory,
                style,
                cell.style_id,
            ) catch |err| id: {
                // If the add failed then either the set needs to grow
                // or it needs to be rehashed. Either one of those can
                // be accomplished by increasing capacity, either with
                // no actual change or with an increased style cap.
                try self.increaseCapacity(list, switch (err) {
                    error.OutOfMemory => .styles,
                    error.NeedsRehash => null,
                });

                // We assume this one will succeed.
                break :id self.page.styles.addWithId(
                    self.page.memory,
                    style,
                    cell.style_id,
                ) catch |err2| {
                    // Should not fail since we just modified capacity
                    // above. Log it, crash in safe builds, clear style
                    // in unsafe builds.
                    log.err(
                        "addWithId failed after capacity increase err={}",
                        .{err2},
                    );
                    if (comptime std.debug.runtime_safety) {
                        // Force a crash with safe builds.
                        unreachable;
                    }

                    self.page_cell.style_id = stylepkg.default_id;
                    break :style;
                };
            } orelse cell.style_id;

            // Update our style cache with the latest style set so runs
            // of cells with the same style are faster to write.
            self.style_cache = .{
                .src_page = src_page,
                .src_id = cell.style_id,
                .dst_id = id,
            };

            self.page_row.styled = true;
            self.page_cell.style_id = id;
        }

        self.cursorForward();
        return .success;
    }

    /// Create a new page in the provided list with the provided
    /// capacity then clone the row currently being worked on to
    /// it and delete it from the old page. Places cursor in the
    /// same position it was in in the old row in the new one.
    ///
    /// Asserts that the cursor is on the final row of the page.
    ///
    /// Expects that the provided capacity is sufficient to copy
    /// the row.
    ///
    /// If this is the only row in the page, the page is removed
    /// from the list after cloning the row.
    fn moveLastRowToNewPage(
        self: *ReflowCursor,
        list: *PageList,
        cap: Capacity,
    ) Allocator.Error!void {
        assert(self.y == self.page.size.rows - 1);
        assert(!self.pending_wrap);

        const old_node = self.node;
        const old_page = self.page;
        const old_row = self.page_row;
        const old_x = self.x;

        // Our total row count never changes, because we're removing one
        // row from the last page and moving it into a new page.
        const old_total_rows = self.total_rows;
        defer self.total_rows = old_total_rows;

        try self.cursorNewPage(list, cap);
        assert(self.node != old_node);
        assert(self.y == 0);

        // We have no cleanup for our old state from here on out. No failures!
        errdefer comptime unreachable;

        // Restore the x position of the cursor.
        self.cursorAbsolute(old_x, 0);

        // Copy our old data. This should NOT fail because we have the
        // capacity of the old page which already fits the data we requested.
        self.page.cloneRowFrom(
            old_page,
            self.page_row,
            old_row,
        ) catch |err| {
            log.err(
                "error cloning single row for moveLastRowToNewPage err={}",
                .{err},
            );
            @panic("unexpected copy row failure");
        };

        // Move any tracked pins from that last row into this new node.
        {
            const pin_keys = list.tracked_pins.keys();
            for (pin_keys) |p| {
                if (p.node.page() != old_page or
                    p.y != old_page.size.rows - 1) continue;

                p.node = self.node;
                p.y = self.y;
                // p.x remains the same since we're copying the row as-is
            }
        }

        // Reset the row on the old page and truncate it. The retired
        // storage must be left in the default state (see resetRow).
        old_page.resetRow(old_row);
        old_page.size.rows -= 1;

        // If that was the last row in that page
        // then we should remove it from the list.
        if (old_page.size.rows == 0) {
            list.pages.remove(old_node);
            list.destroyNode(old_node);
        }
    }

    /// Increase the capacity of the current page.
    fn increaseCapacity(
        self: *ReflowCursor,
        list: *PageList,
        adjustment: ?IncreaseCapacity,
    ) IncreaseCapacityError!void {
        const old_x = self.x;
        const old_y = self.y;
        const old_total_rows = self.total_rows;

        const node = node: {
            // Pause integrity checks because the total row count won't
            // be correct during a reflow.
            list.pauseIntegrityChecks(true);
            defer list.pauseIntegrityChecks(false);
            break :node try list.increaseCapacity(
                self.node,
                adjustment,
            );
        };
        // We must not fail after this, we've modified our self.node
        // and we need to fix it up.
        errdefer comptime unreachable;

        self.* = .init(node);
        self.cursorAbsolute(old_x, old_y);
        self.total_rows = old_total_rows;
    }

    /// True if the string allocator of the current page can fit the
    /// allocations that duping the given source hyperlink performs.
    /// The test allocations are freed before returning.
    ///
    /// This must mirror the exact allocation pattern of
    /// hyperlink.PageEntry.dupe: the URI and the explicit ID (if any)
    /// are allocated separately. The string allocator rounds every
    /// allocation up to its chunk size and requires each allocation to
    /// be contiguous, so a single combined allocation of the total byte
    /// length can succeed where the two separate allocations performed
    /// by dupe would fail.
    fn hyperlinkStringsFit(
        self: *const ReflowCursor,
        src_link: *const hyperlink.PageEntry,
    ) bool {
        const uri_buf = self.page.string_alloc.alloc(
            u8,
            self.page.memory,
            src_link.uri.len,
        ) catch return false;
        defer self.page.string_alloc.free(self.page.memory, uri_buf);

        switch (src_link.id) {
            .implicit => {},
            .explicit => |v| {
                const id_buf = self.page.string_alloc.alloc(
                    u8,
                    self.page.memory,
                    v.len,
                ) catch return false;
                self.page.string_alloc.free(self.page.memory, id_buf);
            },
        }

        return true;
    }

    /// True if this cursor is at the bottom of the page by capacity,
    /// i.e. we can't scroll anymore.
    fn bottom(self: *const ReflowCursor) bool {
        return self.y == self.page.capacity.rows - 1;
    }

    fn cursorForward(self: *ReflowCursor) void {
        if (self.x == self.page.size.cols - 1) {
            self.pending_wrap = true;
        } else {
            const cell: [*]pagepkg.Cell = @ptrCast(self.page_cell);
            self.page_cell = @ptrCast(cell + 1);
            self.x += 1;
        }
    }

    /// Create a new row and move the cursor down.
    ///
    /// Asserts that the cursor is on the bottom row of the
    /// page and that there is capacity to add a new one.
    fn cursorScroll(self: *ReflowCursor) void {
        // Scrolling requires that we're on the bottom of our page.
        // We also assert that we have capacity because reflow always
        // works within the capacity of the page.
        assert(self.y == self.page.size.rows - 1);
        assert(self.page.size.rows < self.page.capacity.rows);

        // Increase our page size
        self.page.size.rows += 1;

        // With the increased page size, safely move down a row.
        const rows: [*]pagepkg.Row = @ptrCast(self.page_row);
        const row: *pagepkg.Row = @ptrCast(rows + 1);
        self.page_row = row;
        self.page_cell = &row.cells.ptr(self.page.memory)[0];
        self.pending_wrap = false;
        self.x = 0;
        self.y += 1;
    }

    /// Create a new page in the provided list with the provided
    /// capacity and one row and move the cursor in to it at 0,0
    fn cursorNewPage(
        self: *ReflowCursor,
        list: *PageList,
        cap: Capacity,
    ) Allocator.Error!void {
        // Remember our new row count so we can restore it
        // after reinitializing our cursor on the new page.
        const new_rows = self.new_rows;

        const node = try list.createPage(.{ .cap = cap });
        errdefer comptime unreachable;
        node.page().size.rows = 1;
        list.pages.insertAfter(self.node, node);

        self.* = .init(node);
        self.new_rows = new_rows;
    }

    /// Performs `cursorScroll` or `cursorNewPage` as necessary
    /// depending on if the cursor is currently at the bottom.
    fn cursorScrollOrNewPage(
        self: *ReflowCursor,
        list: *PageList,
        cap: Capacity,
    ) Allocator.Error!void {
        // The functions below may overwrite self so we need to cache
        // our total rows. We add one because no matter what when this
        // returns we'll have one more row added.
        const new_total_rows: usize = self.total_rows + 1;
        defer self.total_rows = new_total_rows;

        if (self.bottom()) {
            try self.cursorNewPage(list, cap);
        } else {
            self.cursorScroll();
        }
    }

    fn cursorAbsolute(
        self: *ReflowCursor,
        x: size.CellCountInt,
        y: size.CellCountInt,
    ) void {
        assert(x < self.page.size.cols);
        assert(y < self.page.size.rows);

        const rows: [*]pagepkg.Row = @ptrCast(self.page_row);
        const row: *pagepkg.Row = switch (std.math.order(y, self.y)) {
            .eq => self.page_row,
            .lt => @ptrCast(rows - (self.y - y)),
            .gt => @ptrCast(rows + (y - self.y)),
        };
        self.page_row = row;
        self.page_cell = &row.cells.ptr(self.page.memory)[x];
        self.pending_wrap = false;
        self.x = x;
        self.y = y;
    }

    fn countTrailingEmptyCells(self: *const ReflowCursor) usize {
        // If the row is wrapped, all empty cells are meaningful.
        if (self.page_row.wrap) return 0;

        const cells: [*]pagepkg.Cell = @ptrCast(self.page_cell);
        const len: usize = self.page.size.cols - self.x;
        for (0..len) |i| {
            const rev_i = len - i - 1;
            if (!cells[rev_i].isEmpty()) return i;
        }

        // If the row has a semantic prompt then the blank row is meaningful
        // so we always return all but one so that the row is drawn.
        if (self.page_row.semantic_prompt != .none) return len - 1;

        return len;
    }

    fn copyRowMetadata(self: *ReflowCursor, other: *const Row) void {
        self.page_row.semantic_prompt = other.semantic_prompt;
    }
};

fn resizeWithoutReflow(self: *PageList, opts: Resize) Allocator.Error!void {
    // We only set the new minimums if we're not reflowing. If we are
    // reflowing, then the outer resize call handles this for us.
    const old_limits = self.limits;
    if (!opts.reflow) self.limits.resize(
        opts.cols orelse self.cols,
        opts.rows orelse self.rows,
    );
    errdefer self.limits = old_limits;

    // Important! We have to do cols first because cols may cause us to
    // destroy pages if we're increasing cols which will free up page_size
    // so that when we call grow() in the row mods, we won't prune.
    if (opts.cols) |cols| {
        // Any column change without reflow should not result in row counts
        // changing.
        const old_total_rows = self.total_rows;
        defer assert(self.total_rows == old_total_rows);

        switch (std.math.order(cols, self.cols)) {
            .eq => {},

            // Making our columns smaller. We always have space for this
            // in existing pages so we need to go through the pages,
            // resize the columns, and clear any cells that are beyond
            // the new size.
            .lt => {
                var it = self.pageIterator(.right_down, .{ .screen = .{} }, null);
                while (it.next()) |chunk| {
                    const page = chunk.node.page();
                    defer page.assertIntegrity();
                    const rows = page.rows.ptr(page.memory);
                    for (0..page.size.rows) |i| {
                        const row = &rows[i];
                        page.clearCells(row, cols, self.cols);
                    }

                    page.size.cols = cols;
                }

                // Update all our tracked pins. If they have an X
                // beyond the edge, clamp it.
                const pin_keys = self.tracked_pins.keys();
                for (pin_keys) |p| {
                    if (p.x >= cols) p.x = cols - 1;
                }

                self.cols = cols;
            },

            // Make our columns larger. This is a bit more complicated because
            // pages may not have the capacity for this. If they don't have
            // the capacity we need to allocate a new page and copy the data.
            .gt => {
                // See the comment in the while loop when setting self.cols
                const old_cols = self.cols;

                var it = self.pageIterator(.right_down, .{ .screen = .{} }, null);
                while (it.next()) |chunk| {
                    // We need to restore our old cols after we resize because
                    // we have an assertion on this and we want to be able to
                    // call this method multiple times.
                    self.cols = old_cols;
                    try self.resizeWithoutReflowGrowCols(cols, chunk);
                }

                self.cols = cols;
            },
        }
    }

    if (opts.rows) |rows| {
        switch (std.math.order(rows, self.rows)) {
            .eq => {},

            // Making rows smaller, we simply change our rows value. Changing
            // the row size doesn't affect anything else since max size and
            // so on are all byte-based.
            .lt => {
                // If our rows are shrinking, we prefer to trim trailing
                // blank lines from the active area instead of creating
                // history if we can.
                //
                // This matches macOS Terminal.app behavior. I chose to match that
                // behavior because it seemed fine in an ocean of differing behavior
                // between terminal apps. I'm completely open to changing it as long
                // as resize behavior isn't regressed in a user-hostile way.
                const trimmed = self.trimTrailingBlankRows(self.rows - rows);

                // Account for our trimmed rows in the total row cache
                self.total_rows -= trimmed;

                // If we didn't trim enough, just modify our row count and this
                // will create additional history.
                self.rows = rows;
            },

            // Making rows larger we adjust our row count, and then grow
            // to the row count.
            .gt => gt: {
                // If our rows increased and our cursor is NOT at the bottom,
                // we want to try to preserve the y value of the old cursor.
                // In other words, we don't want to "pull down" scrollback.
                // This is purely a UX feature.
                //
                // If we're not allowed to pull scrollback at all then we
                // always do this regardless of the cursor.
                const pull = pull: {
                    if (!opts.pull_scrollback) break :pull false;
                    const cursor = opts.cursor orelse break :pull true;
                    break :pull cursor.y >= self.rows - 1;
                };
                if (!pull) {
                    // We just grow our rows and we're done. Cursor does
                    // NOT change for this since we're not pulling down
                    // scrollback.
                    const delta = rows - self.rows;
                    self.rows = rows;
                    for (0..delta) |_| _ = try self.grow();
                    break :gt;
                }

                // This must be set BEFORE any calls to grow() so that
                // grow() doesn't prune pages that we need for the active
                // area.
                self.rows = rows;

                // Cursor is at the bottom or we don't care about cursors.
                // In this case, if we have enough rows in our pages, we
                // just update our rows and we're done. This effectively
                // "pulls down" scrollback.
                //
                // This traversal intentionally reads only node metadata. A
                // compressed history page pulled into the active area remains
                // compressed until a renderer or other content consumer goes
                // through `Node.page`, which restores it transparently.
                //
                // If we don't have enough scrollback, we add the difference,
                // to the active area.
                var count: usize = 0;
                var page = self.pages.first;
                while (page) |p| : (page = p.next) {
                    count += p.rows();
                    if (count >= rows) break;
                } else {
                    assert(count < rows);
                    for (count..rows) |_| _ = try self.grow();
                }

                // Make sure that the viewport pin isn't below the active
                // area, since that will lead to all sorts of problems.
                switch (self.viewport) {
                    .pin => if (self.pinIsActive(self.viewport_pin.*)) {
                        self.viewport = .active;
                    },
                    .active, .top => {},
                }
            },
        }

        if (build_options.slow_runtime_safety) {
            // We never have less rows than our active screen has.
            assert(self.totalRows() >= self.rows);
        }
    }
}

fn resizeWithoutReflowGrowCols(
    self: *PageList,
    cols: size.CellCountInt,
    chunk: PageIterator.Chunk,
) Allocator.Error!void {
    assert(cols > self.cols);
    const page = chunk.node.page();

    // Update our col count
    const old_cols = self.cols;
    self.cols = cols;
    errdefer self.cols = old_cols;

    // Unlikely fast path: we have capacity in the page. This
    // is only true if we resized to less cols earlier.
    if (page.capacity.cols >= cols) fast: {
        // If any row has a spacer head at the old last column, it will
        // be invalid at the new (wider) size. Fall through to the slow
        // path which handles spacer heads correctly via cloneRowFrom.
        const rows = page.rows.ptr(page.memory)[0..page.size.rows];
        for (rows) |*row| {
            const cells = page.getCells(row);
            if (cells[old_cols - 1].wide == .spacer_head) break :fast;
        }

        page.size.cols = cols;
        return;
    }

    // Likely slow path: we don't have capacity, so we need
    // to allocate a page, and copy the old data into it.

    // Try to fit our new column size into our existing page capacity.
    // If that doesn't work then use a non-standard page with the
    // given columns.
    const cap = page.capacity.adjust(
        .{ .cols = cols },
    ) catch |err| err: {
        comptime assert(@TypeOf(err) == error{OutOfMemory});

        // We verify all maxed out page layouts don't overflow,
        var cap = page.capacity;
        cap.cols = cols;

        // We're growing columns so we can only get less rows so use
        // the lesser of our capacity and size so we minimize wasted
        // rows.
        cap.rows = @min(page.size.rows, cap.rows);
        break :err cap;
    };

    // On error, we need to undo all the pages we've added.
    const prev = chunk.node.prev;
    errdefer {
        var current = chunk.node.prev;
        while (current) |p| {
            if (current == prev) break;
            current = p.prev;
            self.pages.remove(p);
            self.destroyNode(p);
        }
    }

    // Keeps track of all our copied rows. Assertions at the end is that
    // we copied exactly our page size.
    var copied: size.CellCountInt = 0;

    // This function has an unfortunate side effect in that it causes memory
    // fragmentation on rows if the columns are increasing in a way that
    // shrinks capacity rows. If we have pages that don't divide evenly then
    // we end up creating a final page that is not using its full capacity.
    // If this chunk isn't the last chunk in the page list, then we've created
    // a page where we'll never reclaim that capacity. This makes our max size
    // calculation incorrect since we'll throw away data even though we have
    // excess capacity. To avoid this, we try to fill our previous page
    // first if it has capacity.
    //
    // This can fail for many reasons (can't fit styles/graphemes, etc.) so
    // if it fails then we give up and drop back into creating new pages.
    if (prev) |prev_node| prev: {
        const prev_page = prev_node.page();

        // We only want scenarios where we have excess capacity.
        if (prev_page.size.rows >= prev_page.capacity.rows) break :prev;

        // We can copy as much as we can to fill the capacity or our
        // current page size.
        const len = @min(
            prev_page.capacity.rows - prev_page.size.rows,
            page.size.rows,
        );

        const src_rows = page.rows.ptr(page.memory)[0..len];
        const dst_rows = prev_page.rows.ptr(prev_page.memory)[prev_page.size.rows..];
        for (dst_rows, src_rows) |*dst_row, *src_row| {
            prev_page.size.rows += 1;
            copied += 1;
            prev_page.cloneRowFrom(
                page,
                dst_row,
                src_row,
            ) catch {
                // If an error happens, we undo our row copy and break out
                // into creating a new page.
                prev_page.size.rows -= 1;
                copied -= 1;
                break :prev;
            };
        }

        assert(copied == len);
        assert(prev_page.size.rows <= prev_page.capacity.rows);

        // Remap any tracked pins that pointed to rows we just copied to prev.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != chunk.node or p.y >= len) continue;
            p.node = prev_node;
            p.y += prev_page.size.rows - len;
        }
    }

    // If we have an error, we clear the rows we just added to our prev page.
    const prev_copied = copied;
    errdefer if (prev_copied > 0) {
        const prev_page = prev.?.page();
        const prev_size = prev_page.size.rows - prev_copied;
        const prev_rows = prev_page.rows.ptr(prev_page.memory)[prev_size..prev_page.size.rows];
        for (prev_rows) |*row| prev_page.resetRow(row);
        prev_page.size.rows = prev_size;
    };

    // We delete any of the nodes we added.
    errdefer {
        var it = chunk.node.prev;
        while (it) |node| {
            if (node == prev) break;
            it = node.prev;
            self.pages.remove(node);
            self.destroyNode(node);
        }
    }

    // We need to loop because our col growth may force us
    // to split pages.
    while (copied < page.size.rows) {
        const new_node = try self.createPage(.{ .cap = cap });
        const new_page = new_node.page();
        defer new_page.assertIntegrity();

        // The length we can copy into the new page is at most the number
        // of rows in our cap. But if we can finish our source page we use that.
        const len = @min(cap.rows, page.size.rows - copied);

        // Perform the copy
        const y_start = copied;
        const src_rows = page.rows.ptr(page.memory)[y_start .. copied + len];
        const dst_rows = new_page.rows.ptr(new_page.memory)[0..len];
        for (dst_rows, src_rows) |*dst_row, *src_row| {
            new_page.size.rows += 1;
            if (new_page.cloneRowFrom(
                page,
                dst_row,
                src_row,
            )) |_| {
                copied += 1;
            } else |err| {
                // I don't THINK this should be possible, because while our
                // row count may diminish due to the adjustment, our
                // prior capacity should have been sufficient to hold all the
                // managed memory.
                log.warn(
                    "unexpected cloneRowFrom failure during resizeWithoutReflowGrowCols: {}",
                    .{err},
                );

                // We can actually safely handle this though by exiting
                // this loop early and cutting our copy short.
                new_page.size.rows -= 1;
                break;
            }
        }
        const y_end = copied;

        // Insert our new page
        self.pages.insertBefore(chunk.node, new_node);

        // Update our tracked pins that pointed to this previous page.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != chunk.node or
                p.y < y_start or
                p.y >= y_end) continue;
            p.node = new_node;
            p.y -= y_start;
        }
    }
    assert(copied == page.size.rows);

    // Our prior errdeferes are invalid after this point so ensure
    // we don't have any more errors.
    errdefer comptime unreachable;

    // Remove the old page.
    // Deallocate the old page.
    self.pages.remove(chunk.node);
    self.destroyNode(chunk.node);
}

/// Returns the number of trailing blank lines, not to exceed max. Max
/// is used to limit our traversal in the case of large scrollback.
fn trailingBlankLines(
    self: *const PageList,
    max: size.CellCountInt,
) size.CellCountInt {
    var count: size.CellCountInt = 0;

    // Go through our pages backwards since we're counting trailing blanks.
    var it = self.pages.last;
    while (it) |node| : (it = node.prev) {
        const page = node.page();
        const len = node.rows();
        const rows = page.rows.ptr(page.memory)[0..len];
        for (0..len) |i| {
            const rev_i = len - i - 1;
            const cells = rows[rev_i].cells.ptr(page.memory)[0..node.cols()];

            // If the row has any text then we're done.
            if (pagepkg.Cell.hasTextAny(cells)) return count;

            // Inc count, if we're beyond max then we're done.
            count += 1;
            if (count >= max) return count;
        }
    }

    return count;
}

/// Trims up to max trailing blank rows from the pagelist and returns the
/// number of rows trimmed. A blank row is any row with no text (but may
/// have styling).
///
/// IMPORTANT: This function does NOT update `total_rows`. It returns the
/// number of rows trimmed, and the caller is responsible for decrementing
/// `total_rows` by this amount.
fn trimTrailingBlankRows(
    self: *PageList,
    max: size.CellCountInt,
) size.CellCountInt {
    var trimmed: size.CellCountInt = 0;
    var invalidated_node: ?*List.Node = null;
    const bl_pin = self.getBottomRight(.screen).?;
    var it = bl_pin.rowIterator(.left_up, null);
    while (it.next()) |row_pin| {
        const cells = row_pin.cells(.all);

        // If the row has any text then we're done.
        if (pagepkg.Cell.hasTextAny(cells)) return trimmed;

        // If our tracked pins are in this row then we cannot trim it
        // because it implies some sort of importance. If we trimmed this
        // we'd invalidate this pin, as well.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != row_pin.node or
                p.y != row_pin.y) continue;
            return trimmed;
        }

        // No text, we can trim this row. Because it has
        // no text we can also be sure it has no styling
        // so we don't need to worry about memory.
        if (row_pin.node.rows() > 1 and invalidated_node != row_pin.node) {
            // Shrinking a retained page changes its valid row-coordinate range.
            self.invalidateNodeLayout(row_pin.node);
            invalidated_node = row_pin.node;
        }

        // The row has no text but can still carry metadata (e.g. a
        // blank prompt continuation line) and background-colored
        // cells. The retired storage is re-exposed by the grow()
        // fast path without any clearing, so it must be left in the
        // default state.
        row_pin.node.page().resetRow(row_pin.rowAndCell().row);

        row_pin.node.page().size.rows -= 1;
        if (row_pin.node.page().size.rows == 0) {
            self.erasePage(row_pin.node);
        } else {
            row_pin.node.page().assertIntegrity();
        }

        trimmed += 1;
        if (trimmed >= max) return trimmed;
    }

    return trimmed;
}

/// Scroll options.
pub const Scroll = union(enum) {
    /// Scroll to the active area. This is also sometimes referred to as
    /// the "bottom" of the screen. This makes it so that the end of the
    /// screen is fully visible since the active area is the bottom
    /// rows/cols of the screen.
    active,

    /// Scroll to the top of the screen, which is the farthest back in
    /// the scrollback history.
    top,

    /// Scroll to the given absolute row from the top. A value of zero
    /// is the top row. This row will be the first visible row in the viewport.
    /// Scrolling into or below the active area will clamp to the active area.
    row: usize,

    /// Scroll up (negative) or down (positive) by the given number of
    /// rows. This is clamped to the "top" and "active" top left.
    delta_row: isize,

    /// Jump forwards (positive) or backwards (negative) a set number of
    /// prompts. If the absolute value is greater than the number of prompts
    /// in either direction, jump to the furthest prompt in that direction.
    delta_prompt: isize,

    /// Scroll directly to a specific pin in the page. This will be set
    /// as the top left of the viewport (ignoring the pin x value).
    pin: Pin,
};

/// Scroll the viewport. This will never create new scrollback, allocate
/// pages, etc. This can only be used to move the viewport within the
/// previously allocated pages.
pub fn scroll(self: *PageList, behavior: Scroll) void {
    defer self.assertIntegrity();

    // Special case no-scrollback mode to never allow scrolling.
    if (self.limits.bytes.explicit == 0) {
        self.viewport = .active;
        return;
    }

    // Moving the viewport changes which historical pages are visible. Restart
    // traversal so pages which leave the viewport are reconsidered after the
    // renderer's idle delay. False positives from clamped scrolling are cheap.
    defer {
        self.page_compression.reset();
        self.page_compression.markActivity();
    }

    switch (behavior) {
        .active => self.viewport = .active,
        .top => self.viewport = .top,
        .pin => |p| {
            if (self.pinIsActive(p)) {
                self.viewport = .active;
                return;
            } else if (self.pinIsTop(p)) {
                self.viewport = .top;
                return;
            }

            self.viewport_pin.* = p;
            self.viewport = .pin;
            self.viewport_pin_row_offset = null; // invalidate cache
        },
        .row => |n| row: {
            // If we're at the top, pin the top.
            if (n == 0) {
                self.viewport = .top;
                break :row;
            }

            // If we're below the top of the active area, pin the active area.
            if (n >= self.total_rows - self.rows) {
                self.viewport = .active;
                break :row;
            }

            // See if there are any other faster paths we can take.
            switch (self.viewport) {
                .top, .active => {},
                .pin => if (self.viewport_pin_row_offset) |*v| {
                    // If we have a pin and we already calculated a row offset,
                    // then we can efficiently calculate the delta and move
                    // that much from that pin.
                    const delta: isize = delta: {
                        const n_isize: isize = @intCast(n);
                        const v_isize: isize = @intCast(v.*);
                        break :delta n_isize - v_isize;
                    };
                    self.scroll(.{ .delta_row = delta });
                    return;
                },
            }

            // We have an accurate row offset so store it to prevent
            // calculating this again.
            self.viewport_pin_row_offset = n;
            self.viewport = .pin;

            // Slow path, we've just got to traverse the linked list and
            // get to our row. As a slight speedup, let's pick the traversal
            // that's likely faster based on our absolute row and total rows.
            const midpoint = self.total_rows / 2;
            if (n < midpoint) {
                // Iterate forward from the first node.
                var node_it = self.pages.first;
                var rem: usize = n;
                while (node_it) |node| : (node_it = node.next) {
                    if (rem < node.rows()) {
                        self.viewport_pin.* = .{
                            .node = node,
                            .y = std.math.cast(size.CellCountInt, rem) orelse {
                                self.viewport = .active;
                                break :row;
                            },
                        };
                        break :row;
                    }

                    rem -= node.rows();
                }
            } else {
                // Iterate backwards from the last node.
                var node_it = self.pages.last;
                var rem: usize = self.total_rows - n;
                while (node_it) |node| : (node_it = node.prev) {
                    if (rem <= node.rows()) {
                        self.viewport_pin.* = .{
                            .node = node,
                            .y = std.math.cast(size.CellCountInt, node.rows() - rem) orelse {
                                self.viewport = .active;
                                break :row;
                            },
                        };
                        break :row;
                    }

                    rem -= node.rows();
                }
            }

            // If we reached here, then we couldn't find the offset.
            // This feels impossible? Just clamp to active, screw it lol.
            self.viewport = .active;
        },
        .delta_prompt => |n| self.scrollPrompt(n),
        .delta_row => |n| delta_row: {
            const amount: usize = @abs(n);

            switch (self.viewport) {
                // If we're at the top and we're scrolling backwards,
                // we don't have to do anything, because there's nowhere to go.
                .top => if (n <= 0) break :delta_row,

                // If we're at active and we're scrolling forwards, we don't
                // have to do anything because it'll result in staying in
                // the active.
                .active => if (n >= 0) break :delta_row,

                // If we're already a pin type, then we can fast-path our
                // delta by simply moving the pin. This has the added benefit
                // that we can update our row offset cache efficiently, too.
                .pin => switch (std.math.order(n, 0)) {
                    .eq => break :delta_row,

                    .lt => switch (self.viewport_pin.upOverflow(amount)) {
                        .offset => |new_pin| {
                            self.viewport_pin.* = new_pin;
                            if (self.viewport_pin_row_offset) |*v| {
                                v.* -= amount;
                            }
                            break :delta_row;
                        },

                        // If we overflow up we're at the top.
                        .overflow => {
                            self.viewport = .top;
                            break :delta_row;
                        },
                    },

                    .gt => switch (self.viewport_pin.downOverflow(amount)) {
                        // If we offset its a valid pin but we still have to
                        // check if we're in the active area.
                        .offset => |new_pin| {
                            if (self.pinIsActive(new_pin)) {
                                self.viewport = .active;
                            } else {
                                self.viewport_pin.* = new_pin;
                                if (self.viewport_pin_row_offset) |*v| {
                                    v.* += amount;
                                }
                            }
                            break :delta_row;
                        },

                        // If we overflow down we're at active.
                        .overflow => {
                            self.viewport = .active;
                            break :delta_row;
                        },
                    },
                },
            }

            // Slow path: we have to calculate the new pin by moving
            // from our viewport.
            const top = self.getTopLeft(.viewport);
            const p: Pin = if (n < 0) switch (top.upOverflow(amount)) {
                .offset => |v| v,
                .overflow => |v| v.end,
            } else switch (top.downOverflow(amount)) {
                .offset => |v| v,
                .overflow => |v| v.end,
            };

            // If we are still within the active area, then we pin the
            // viewport to active. This isn't EXACTLY the same behavior as
            // other scrolling because normally when you scroll the viewport
            // is pinned to _that row_ even if new scrollback is created.
            // But in a terminal when you get to the bottom and back into the
            // active area, you usually expect that the viewport will now
            // follow the active area.
            if (self.pinIsActive(p)) {
                self.viewport = .active;
                return;
            }

            // If we're at the top, then just set the top. This is a lot
            // more efficient everywhere. We must check this after the
            // active check above because we prefer active if they overlap.
            if (self.pinIsTop(p)) {
                self.viewport = .top;
                return;
            }

            // Pin is not active so we need to track it.
            self.viewport_pin.* = p;
            self.viewport = .pin;
            self.viewport_pin_row_offset = null; // invalidate cache
        },
    }
}

/// Jump the viewport forwards (positive) or backwards (negative) a set number of
/// prompts (delta).
fn scrollPrompt(self: *PageList, delta: isize) void {
    // If we aren't jumping any prompts then we don't need to do anything.
    if (delta == 0) return;
    const delta_start: usize = @abs(delta);
    var delta_rem: usize = delta_start;

    // We start at the row before or after our viewport depending on the
    // delta so that we don't land back on our current viewport.
    const start_pin = start: {
        const tl = self.getTopLeft(.viewport);

        // If we're moving up we can just move the viewport up because
        // promptIterator handles jumpting to the start of prompts.
        if (delta <= 0) break :start tl.up(1) orelse return;

        // If we're moving down and we're presently at some kind of
        // prompt, we need to skip all the continuation lines because
        // promptIterator can't know if we're cutoff or continuing.
        var adjusted: Pin = tl.down(1) orelse return;
        if (tl.rowAndCell().row.semantic_prompt != .none) skip: {
            while (adjusted.rowAndCell().row.semantic_prompt == .prompt_continuation) {
                adjusted = adjusted.down(1) orelse break :skip;
            }
        }

        break :start adjusted;
    };

    // Go through prompts delta times
    var it = start_pin.promptIterator(
        if (delta > 0) .right_down else .left_up,
        null,
    );
    var prompt_pin: ?Pin = null;
    while (it.next()) |next| {
        prompt_pin = next;
        delta_rem -= 1;
        if (delta_rem == 0) break;
    }

    // If we found a prompt, we move to it. If the prompt is in the active
    // area we keep our viewport as active because we can't scroll DOWN
    // into the active area. Otherwise, we scroll up to the pin.
    if (prompt_pin) |p| {
        if (self.pinIsActive(p)) {
            self.viewport = .active;
        } else {
            self.viewport_pin.* = p;
            self.viewport = .pin;
            self.viewport_pin_row_offset = null; // invalidate cache
        }
    }
}

/// Clear the screen by scrolling written contents up into the scrollback.
/// This will not update the viewport.
pub fn scrollClear(self: *PageList) Allocator.Error!void {
    defer self.assertIntegrity();

    // Go through the active area backwards to find the first non-empty
    // row. We use this to determine how many rows to scroll up.
    const non_empty: usize = non_empty: {
        var page = self.pages.last.?;
        var n: usize = 0;
        while (true) {
            const current_page = page.page();
            const rows: [*]Row = current_page.rows.ptr(current_page.memory);
            for (0..page.rows()) |i| {
                const rev_i = page.rows() - i - 1;
                const row = rows[rev_i];
                const cells = row.cells.ptr(current_page.memory)[0..self.cols];
                for (cells) |cell| {
                    if (!cell.isEmpty()) break :non_empty self.rows - n;
                }

                n += 1;
                if (n > self.rows) break :non_empty 0;
            }

            page = page.prev orelse break :non_empty 0;
        }
    };

    // Scroll
    for (0..non_empty) |_| _ = try self.grow();
}

/// Give a live node a new generation before changing its coordinate layout in
/// place.
///
/// This must be called when a node remains at the same address and stays in the
/// list, but a mutation changes which logical row a `(node, y)` coordinate
/// identifies or whether that coordinate is still in range. Examples include
/// rotating rows after an erase, truncating a page's row range, reinitializing
/// the sole remaining page, or shortening the source page of a split. Without
/// a new generation, a cached pointer, serial, and coordinate could still pass
/// `nodeIsValid` while referring to a different row than it originally did.
/// Screen and Terminal fast paths which manipulate Page rows directly must use
/// this because they bypass PageList's own row-mutation helpers.
///
/// The caller must pass a node which is currently live in this PageList. Call
/// this at the point the operation commits to changing the layout and before
/// the first such change. When an operation is intended to be atomic, finish
/// its failable preparation first so a failed operation does not needlessly
/// invalidate references. One call per affected node is sufficient when an
/// operation performs several layout changes without exposing intermediate
/// references.
///
/// This helper is only needed for in-place changes. Removing or replacing a
/// node already invalidates old references through the live-list check in
/// `nodeIsValid`, and newly allocated or reused nodes receive a fresh serial as
/// part of their initialization. Ordinary cell or style changes which preserve
/// the meaning of page coordinates do not require a new generation solely for
/// that reason.
///
/// The only state changed here is `node.serial` and the next-generation counter
/// `page_serial`. Consequently, every previously captured pointer-plus-serial
/// pair for this node becomes invalid while new references can capture the new
/// generation. This does not advance `page_serial_epoch`: only `reset` starts a
/// new whole-list validity epoch.
///
/// This also does not mutate the page, update tracked pins or viewport state,
/// adjust row or memory accounting, mark cells dirty, or notify incremental
/// compression. The surrounding operation remains responsible for all such
/// bookkeeping required by its layout change.
pub fn invalidateNodeLayout(self: *PageList, node: *List.Node) void {
    node.serial = self.page_serial;
    self.page_serial += 1;
}

/// Compact a page to use the minimum required memory for the contents
/// it stores. Returns the new node pointer if compaction occurred, or null
/// if the page was already compact or compaction would not provide any
/// savings.
///
/// The compacted page is always an exact-size heap allocation, never
/// a pool item, since a pool item always retains a full std_size
/// buffer regardless of the page layout. Note that this means that
/// when compacting a pool-owned node, the freed pool item is returned
/// to the pool free list, so the memory savings are only fully
/// realized once the pool itself is reset or freed.
///
/// If this returns OOM, the PageList is left unchanged and no dangling
/// memory references exist. It is safe to ignore the error and continue using
/// the uncompacted page.
pub fn compact(self: *PageList, node: *List.Node) Allocator.Error!?*List.Node {
    defer self.assertIntegrity();
    const page: *Page = node.page();

    // We should never have empty rows in our pagelist anyways...
    assert(page.size.rows > 0);

    // Compute the minimum capacity required for this page's content
    const req_cap = page.exactRowCapacity(0, page.size.rows);
    const new_size = Page.layout(req_cap).total_size;

    // The memory this node currently retains. A pool-owned node always
    // retains a full pool item no matter its layout size.
    const old_size: usize = switch (node.owned) {
        .pool => PagePool.item_size,
        .heap => page.memory.len,
    };
    if (new_size >= old_size) return null;

    // Create the new smaller page
    const new_node = try self.createPage(.{
        .cap = req_cap,
        .exact_size = true,
    });
    errdefer self.destroyNode(new_node);
    const new_page: *Page = new_node.page();
    new_page.size = page.size;
    new_page.dirty = page.dirty;
    new_page.cloneFrom(
        page,
        0,
        page.size.rows,
    ) catch |err| {
        // cloneFrom should not fail when compacting since req_cap is
        // computed to exactly fit the source content and our expectation
        // of exactRowCapacity ensures it can fit all the requested
        // data.
        log.err("compact clone failed err={}", .{err});

        // In this case, let's gracefully degrade by pretending we
        // didn't need to compact.
        self.destroyNode(new_node);
        return null;
    };

    // Fix up all tracked pins to point to the new page
    const pin_keys = self.tracked_pins.keys();
    for (pin_keys) |p| {
        if (p.node != node) continue;
        p.node = new_node;
    }

    // Insert the new page and destroy the old one
    self.pages.insertBefore(node, new_node);
    self.pages.remove(node);
    self.destroyNode(node);
    self.page_compression.markActivity();

    new_page.assertIntegrity();
    return new_node;
}

pub const SplitError = error{
    // Allocator OOM
    OutOfMemory,
    // Page can't be split further because it is already a single row.
    OutOfSpace,
};

/// Split the given node in the PageList at the given pin.
///
/// The row at the pin and after will be moved into a new page with
/// the same capacity as the original page. Alternatively, you can "split
/// above" by splitting the row following the desired split row.
///
/// Since the split happens below the pin, the pin remains valid.
pub fn split(
    self: *PageList,
    p: Pin,
) SplitError!void {
    if (build_options.slow_runtime_safety) assert(self.pinIsValid(p));

    // Ran into a bug that I can only explain via aliasing. If a tracked
    // pin is passed in, its possible Zig will alias the memory and then
    // when we modify it later it updates our p here. Copying the node
    // fixes this.
    const original_node = p.node;
    const page: *Page = original_node.page();

    // A page that is already 1 row can't be split. In the future we can
    // theoretically maybe split by soft-wrapping multiple pages but that
    // seems crazy and the rest of our PageList can't handle heterogeneously
    // sized pages today.
    if (page.size.rows <= 1) return error.OutOfSpace;

    // Splitting at row 0 is a no-op since there's nothing before the split point.
    if (p.y == 0) return;

    // At this point we're doing actual modification so make sure
    // on the return that we're good.
    defer self.assertIntegrity();

    // Create a new node with the same capacity of managed memory.
    const target = try self.createPage(.{ .cap = page.capacity });
    errdefer self.destroyNode(target);

    // Determine how many rows we're copying
    const y_start = p.y;
    const y_end = page.size.rows;
    target.page().size.rows = y_end - y_start;
    assert(target.rows() <= target.capacity().rows);

    // Copy our old data. This should NOT fail because we have the
    // capacity of the old page which already fits the data we requested.
    target.page().cloneFrom(page, y_start, y_end) catch |err| {
        log.err(
            "error cloning rows for split err={}",
            .{err},
        );

        // Rather than crash, we return an OutOfSpace to show that
        // we couldn't split and let our callers gracefully handle it.
        // Realistically though... this should not happen.
        return error.OutOfSpace;
    };

    // From this point forward there is no going back. We have no
    // error handling. It is possible but we haven't written it.
    errdefer comptime unreachable;

    // Failable split work is complete; shortening the source changes its row range.
    self.invalidateNodeLayout(original_node);
    self.page_compression.markActivity();

    // Move any tracked pins from the copied rows
    for (self.tracked_pins.keys()) |tracked| {
        if (tracked.node.page() != page or
            tracked.y < p.y) continue;

        tracked.node = target;
        tracked.y -= p.y;
        // p.x remains the same since we're copying the row as-is
    }

    // Reset our rows. They are retired into unused page capacity,
    // which the grow() fast path re-exposes without any clearing, so
    // they must be left in the default state.
    for (page.rows.ptr(page.memory)[y_start..y_end]) |*row| {
        page.resetRow(row);
    }
    page.size.rows -= y_end - y_start;

    self.pages.insertAfter(original_node, target);
}

/// This represents the state necessary to render a scrollbar for this
/// PageList. It has the total size, the offset, and the size of the viewport.
pub const Scrollbar = struct {
    /// Total size of the scrollable area.
    total: usize,

    /// The offset into the total area that the viewport is at. This is
    /// guaranteed to be less than or equal to total. This includes the
    /// visible row.
    offset: usize,

    /// The length of the visible area. This is including the offset row.
    len: usize,

    /// A zero-sized scrollable region.
    pub const zero: Scrollbar = .{
        .total = 0,
        .offset = 0,
        .len = 0,
    };

    // Sync with: ghostty_action_scrollbar_s
    pub const C = extern struct {
        total: u64,
        offset: u64,
        len: u64,
    };

    pub fn cval(self: Scrollbar) C {
        return .{
            .total = @intCast(self.total),
            .offset = @intCast(self.offset),
            .len = @intCast(self.len),
        };
    }

    /// Comparison for scrollbars.
    pub fn eql(self: Scrollbar, other: Scrollbar) bool {
        return self.total == other.total and
            self.offset == other.offset and
            self.len == other.len;
    }
};

/// Return the scrollbar state for this PageList.
///
/// This is amortized O(1): the total is maintained incrementally and
/// the viewport offset is cached. The first call after the viewport
/// moves to an arbitrary pin (e.g. scrolling to a selection) may cost
/// O(pages) to compute the offset, after which it is cached again.
/// See viewportRowOffset for more details.
pub fn scrollbar(self: *PageList) Scrollbar {
    // If we have no scrollback, special case no scrollbar.
    // We need to do this because the way PageList works is that
    // it always has SOME extra space (due to the way we allocate by page).
    // So even with no scrollback we have some growth. It is architecturally
    // much simpler to just hide that for no-scrollback cases.
    if (self.limits.bytes.explicit == 0) return .{
        .total = self.rows,
        .offset = 0,
        .len = self.rows,
    };

    return .{
        .total = self.total_rows,
        .offset = self.viewportRowOffset(),
        .len = self.rows, // Length is always rows
    };
}

/// Returns the offset of the current viewport from the top of the
/// screen.
///
/// This is potentially expensive to calculate because if the viewport
/// is a pin and the pin is near the beginning of the scrollback, we
/// will traverse a lot of linked list nodes.
///
/// The result is cached so repeated calls are cheap.
fn viewportRowOffset(self: *PageList) usize {
    return switch (self.viewport) {
        .top => 0,
        .active => self.total_rows - self.rows,
        .pin => pin: {
            // We assert integrity on this code path because it verifies
            // that the cached value is correct.
            defer self.assertIntegrity();

            // Return cached value if available
            if (self.viewport_pin_row_offset) |cached| break :pin cached;

            // Traverse from the end and count rows until we reach the
            // viewport pin. We count backwards because most of the time
            // a user is scrolling near the active area.
            const top_offset: usize = offset: {
                var offset: usize = 0;
                var node = self.pages.last;
                while (node) |n| : (node = n.prev) {
                    offset += n.rows();
                    if (n == self.viewport_pin.node) {
                        assert(n.rows() > self.viewport_pin.y);
                        offset -= self.viewport_pin.y;
                        break :offset self.total_rows - offset;
                    }
                }

                // Invalid pins are not possible.
                unreachable;
            };

            // The offset is from the bottom and our cached value and this
            // function returns from the top, so we need to invert it.
            self.viewport_pin_row_offset = top_offset;
            break :pin top_offset;
        },
    };
}

/// This fixes up the viewport data when rows are removed from the
/// PageList. This will update a viewport to `active` if row removal
/// puts the viewport into the active area, to `top` if the viewport
/// is now at row 0, and updates any row offset caches as necessary.
///
/// This is unit tested transitively through other tests such as
/// eraseRows.
fn fixupViewport(
    self: *PageList,
    removed: usize,
) void {
    // Page removal can mark every pin on the removed page as garbage. The
    // viewport pin is an internal navigation anchor that is always remapped,
    // so it remains valid after the removal.
    self.viewport_pin.garbage = false;

    switch (self.viewport) {
        .active => {},

        // For pin, we check if our pin is now in the active area and if so
        // we move our viewport back to the active area.
        .pin => if (self.pinIsActive(self.viewport_pin.*)) {
            self.viewport = .active;
        } else if (self.viewport_pin_row_offset) |*v| {
            // If we have a cached row offset, we need to update it
            // to account for the erased rows.
            if (v.* < removed) {
                self.viewport = .top;
            } else {
                v.* -= removed;
            }
        },

        // For top, we move back to active if our erasing moved our
        // top page into the active area.
        .top => if (self.pinIsActive(.{ .node = self.pages.first.? })) {
            self.viewport = .active;
        },
    }
}

/// Change the maximum logical page allocation at runtime. Null removes the
/// explicit byte limit and zero disables scrollback.
///
/// Lowering the limit immediately removes eligible complete historical pages.
/// The effective limit may still be raised to fit the active area, and a page
/// which overlaps the active area is never split solely to satisfy this limit.
pub fn setMaxBytes(self: *PageList, max: ?usize) void {
    defer self.assertIntegrity();

    self.limits.set(.bytes, max);
    self.limits.enforce(self, .bytes);
    if (self.limits.bytes.explicit == 0) self.viewport = .active;
}

/// Change the maximum number of physical scrollback rows at runtime. Null
/// removes the explicit line limit.
///
/// Lowering the limit immediately removes eligible complete historical pages.
/// The effective limit always permits at least one standard page of history,
/// and a page which overlaps the active area is never split for enforcement.
pub fn setMaxLines(self: *PageList, max: ?usize) void {
    defer self.assertIntegrity();

    self.limits.set(.lines, max);
    self.limits.enforce(self, .lines);
}

/// Grow the active area by exactly one row.
///
/// This may allocate, but also may not if our current page has more
/// capacity we can use. This will prune scrollback if necessary to
/// adhere to max_size and max_lines.
///
/// This returns the newly allocated page node if there is one.
pub fn grow(self: *PageList) Allocator.Error!?*List.Node {
    defer self.assertIntegrity();

    // Growing can move a complete page behind the active boundary.
    self.page_compression.markActivity();

    const last = self.pages.last.?;
    if (last.capacity().rows > last.rows()) {
        // Fast path: we have capacity in the last page. The exposed
        // row requires no clearing work here: rows in unused page
        // capacity are always in the default zero state, either
        // because the page memory was never used (pool buffers are
        // zeroed) or because whatever retired the row reset it (see
        // Page.resetRow).
        const page = last.page();
        page.size.rows += 1;
        page.assertIntegrity();

        // Increase our total rows by one
        self.total_rows += 1;

        // Growing inside the last page moves the active boundary without
        // allocating; that alone can make the first page wholly historical.
        self.limits.enforce(self, .lines);
        return null;
    }

    // Slower path: we have no space, we need to allocate a new page.

    // Get the layout first so our failable work is done early.
    // We'll need this for both paths.
    const cap = initialCapacity(self.cols);

    // If allocation would exceed our max size, we prune the first page.
    // We don't need to reallocate because we can simply reuse that first
    // page.
    //
    // We only take this path if we have more than one page since pruning
    // reuses the popped page. It is possible to have a single page and
    // exceed the max size if that page was adjusted to be larger after
    // initial allocation.
    if (self.pages.first != null and
        self.pages.first != self.pages.last and
        self.page_size + PagePool.item_size > self.limits.max(.bytes))
    prune: {
        const first = self.pages.popFirst().?;
        assert(first != last);

        // Decrease our total row count from the pruned page
        self.total_rows -= first.rows();

        // If our total row count is now less than our required
        // rows then we can't prune. The "+ 1" is because we'll add one
        // more row below.
        if (self.total_rows + 1 < self.rows) {
            self.pages.prepend(first);
            assert(self.pages.first == first);
            self.total_rows += first.rows();
            break :prune;
        }

        // If we have a pin viewport cache then we need to update it.
        if (self.viewport == .pin) viewport: {
            if (self.viewport_pin_row_offset) |*v| {
                // If our offset is less than the number of rows in the
                // pruned page, then we are now at the top.
                if (v.* < first.rows()) {
                    self.viewport = .top;
                    break :viewport;
                }

                // Otherwise, our viewport pin is below what we pruned
                // so we just decrement our offset.
                v.* -= first.rows();
            }
        }

        // Update any tracked pins that point to this page to point to the
        // new first page to the top-left, and mark them as garbage.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != first) continue;
            p.node = self.pages.first.?;
            p.y = 0;
            p.x = 0;
            p.garbage = true;
        }
        self.viewport_pin.garbage = false;

        switch (first.owned) {
            // Pool-owned pages are reused below.
            .pool => {},

            // Heap-owned pages can't be reused because they may be
            // any size (larger or smaller than a standard page), so
            // just destroy them.
            .heap => {
                self.destroyNode(first);
                break :prune;
            },
        }

        // Reset our memory
        const buf = first.restore(.discard).memory;
        @memset(buf, 0);
        assert(buf.len <= std_size);

        // Initialize our new page and reinsert it as the last
        first.data = .{ .resident = .initBuf(.init(buf), Page.layout(cap)) };
        const page = first.page();
        page.size.rows = 1;
        self.pages.insertAfter(last, first);
        self.total_rows += 1;

        // Reusing the node gives it a fresh generation. Do not begin a new
        // page_serial_epoch here: generations are not monotonic in list order,
        // so older live successors may have lower generations. The epoch only
        // advances when reset invalidates the entire list.
        first.serial = self.page_serial;
        self.page_serial += 1;

        // In this case we do NOT need to update page_size because
        // we're reusing an existing page so nothing has changed.

        page.assertIntegrity();

        // Byte-limit recycling may leave history above the independent line
        // limit, so enforce it after the recycled page becomes the new tail.
        self.limits.enforce(self, .lines);
        return first;
    }

    // We need to allocate a new memory buffer.
    const next_node = try self.createPage(.{ .cap = cap });
    // we don't errdefer this because we've added it to the linked
    // list and its fine to have dangling unused pages.
    self.pages.append(next_node);
    const page = next_node.page();
    page.size.rows = 1;

    // We should never be more than our max size here because we've
    // verified the case above.
    page.assertIntegrity();

    // Record the increased row count
    self.total_rows += 1;

    // Appending a page can cross the line limit and can make the oldest
    // active-boundary page wholly historical.
    self.limits.enforce(self, .lines);
    return next_node;
}

/// Possible dimensions to increase capacity for.
pub const IncreaseCapacity = enum {
    styles,
    grapheme_bytes,
    hyperlink_bytes,
    string_bytes,

    /// Returns the capacity dimension that must be increased for the
    /// given row clone error to succeed on retry, or null if the page
    /// only needs to be rehashed at its current capacity.
    pub fn forCloneError(err: Page.CloneFromError) ?IncreaseCapacity {
        return switch (err) {
            // Rehash the sets
            error.StyleSetNeedsRehash,
            error.HyperlinkSetNeedsRehash,
            => null,

            // Increase style memory
            error.StyleSetOutOfMemory,
            => .styles,

            // Increase string memory
            error.StringAllocOutOfMemory,
            => .string_bytes,

            // Increase hyperlink memory
            error.HyperlinkSetOutOfMemory,
            error.HyperlinkMapOutOfMemory,
            => .hyperlink_bytes,

            // Increase grapheme memory
            error.GraphemeMapOutOfMemory,
            error.GraphemeAllocOutOfMemory,
            => .grapheme_bytes,
        };
    }
};

pub const IncreaseCapacityError = error{
    // An actual system OOM trying to allocate memory.
    OutOfMemory,

    // The existing page is already at max capacity for the given
    // adjustment. The caller must create a new page, remove data from
    // the old page, etc. (up to the caller).
    OutOfSpace,
};

/// Increase the capacity of the given page node in the given direction.
/// This will always allocate a new node and remove the old node, so the
/// existing node pointer will be invalid after this call. The newly created
/// node on success is returned.
///
/// The increase amount is at the control of the PageList implementation,
/// but is guaranteed to always increase by at least one unit in the
/// given dimension. Practically, we'll always increase by much more
/// (we currently double every time) but callers shouldn't depend on that.
/// The only guarantee is some amount of growth.
///
/// Adjustment can be null if you want to recreate, reclone the page
/// with the same capacity. This is a special case used for rehashing since
/// the logic is otherwise the same. In this case, OutOfMemory is the
/// only possible error.
pub fn increaseCapacity(
    self: *PageList,
    node: *List.Node,
    adjustment: ?IncreaseCapacity,
) IncreaseCapacityError!*List.Node {
    defer self.assertIntegrity();
    const page: *Page = node.page();

    // Apply our adjustment
    var cap = page.capacity;
    if (adjustment) |v| switch (v) {
        inline else => |tag| {
            const field_name = @tagName(tag);
            const Int = @FieldType(Capacity, field_name);
            const old = @field(cap, field_name);

            const new: Int = new: {
                // A dimension can be zero for pages with exact
                // capacities (see compact). Doubling zero stays zero,
                // which would break our guarantee that we always
                // increase by at least one unit and turn caller retry
                // loops into infinite loops. Jump straight to the
                // standard default instead: it is what all standard
                // pages start with, so retrying callers are guaranteed
                // enough room for their pending allocation.
                if (old == 0) {
                    const default: Capacity = .{ .cols = 0, .rows = 0 };
                    break :new @field(default, field_name);
                }

                // We use checked math to prevent overflow. If there is
                // an overflow it means we're out of space in this
                // dimension, since pages can take up to their maxInt
                // capacity in any category.
                break :new std.math.mul(
                    Int,
                    old,
                    2,
                ) catch |err| overflow: {
                    comptime assert(@TypeOf(err) == error{Overflow});
                    // Our final doubling would overflow since maxInt is
                    // 2^N - 1 for an unsignged int of N bits. So, if we overflow
                    // and we haven't used all the bits, use all the bits.
                    if (old < std.math.maxInt(Int)) break :overflow std.math.maxInt(Int);
                    return error.OutOfSpace;
                };
            };
            @field(cap, field_name) = new;

            // If our capacity exceeds the maximum page size, treat it
            // as an OutOfSpace because things like page splitting will
            // help.
            const layout = Page.layout(cap);
            if (layout.total_size > size.max_page_size) {
                return error.OutOfSpace;
            }

            // Doubling alone has a really bad behavior in that if you're
            // in a pathological scenario with only one dimension of cap
            // increase, you have to pay repeat double costs. Each time you
            // double we have to reclone the entire page. As the page gets
            // bigger this gets more expensive.
            //
            // Instead, for some dimensions, we do something else: we look
            // at the current utilization, and project that to every row
            // in the page capacity (if it fits). We just assume that your
            // future workload will look the one you're currently filling.
            // If we're wrong, its some wasted capacity but future growth
            // still works in other dimensions.
            //
            // This only applies to the current page being grown. I previously
            // tried a high-water-mark style solution to preallocate pages,
            // which does work really well, but its not clear when you reset
            // the mark.
            project: {
                // The dimensions we project must measure their current
                // usage in the same units as the capacity field.
                const used: u64 = switch (comptime tag) {
                    .grapheme_bytes => page.grapheme_alloc.usedBytes(page.memory),

                    // Living item count. Note the capacity field is a
                    // requested item count that Layout.init rounds in
                    // both directions (table to the next power of two,
                    // items to the load factor of that), so this is an
                    // approximation in capacity units; the headroom
                    // below absorbs the error and an undershoot only
                    // costs one more (non-ladder) growth event.
                    .styles => page.styles.count(),

                    else => break :project,
                };
                if (used == 0 or page.size.rows == 0) break :project;

                // Full-page need at current density, plus 25% headroom
                // for chunk rounding and fragmentation.
                const density = used * @as(u64, cap.rows) / page.size.rows;
                const projected_raw = density + density / 4;

                // Bound the jump to 32× the pre-growth capacity. Arbitrary
                // choice until we can show otherwise.
                const projected = @min(
                    projected_raw,
                    @as(u64, old) * 32,
                    std.math.maxInt(Int),
                );
                if (projected <= @field(cap, field_name)) break :project;

                // Only take the projection if the resulting page still fits.
                var proj_cap = cap;
                @field(proj_cap, field_name) = @intCast(projected);
                if (Page.layout(proj_cap).total_size > size.max_page_size)
                    break :project;
                cap = proj_cap;
            }
        },
    };

    log.info("adjusting page capacity={}", .{cap});

    // Create our new page and clone the old page into it.
    const new_node = try self.createPage(.{ .cap = cap });
    errdefer self.destroyNode(new_node);
    const new_page: *Page = new_node.page();
    assert(new_page.capacity.rows >= page.capacity.rows);
    assert(new_page.capacity.cols >= page.capacity.cols);
    new_page.size.rows = page.size.rows;
    new_page.size.cols = page.size.cols;
    new_page.cloneFrom(
        page,
        0,
        page.size.rows,
    ) catch |err| {
        // cloneFrom only errors if there isn't capacity for the data
        // from the source page but we're only increasing capacity so
        // this should never be possible. If it happens, we should crash
        // because we're in no man's land and can't safely recover.
        log.err("increaseCapacity clone failed err={}", .{err});
        @panic("unexpected clone failure");
    };

    // Preserve page-level dirty flag (cloneFrom only copies row data)
    new_page.dirty = page.dirty;

    // Must not fail after this because the operations we do after this
    // can't be recovered.
    errdefer comptime unreachable;

    // Fix up all our tracked pins to point to the new page.
    const pin_keys = self.tracked_pins.keys();
    for (pin_keys) |p| {
        if (p.node != node) continue;
        p.node = new_node;
    }

    // Insert this page and destroy the old page
    self.pages.insertBefore(node, new_node);
    self.pages.remove(node);
    self.destroyNode(node);
    self.page_compression.markActivity();

    new_page.assertIntegrity();
    return new_node;
}

/// Options for createPage and createPageExt.
const CreatePage = struct {
    /// The capacity to allocate the page with.
    cap: Capacity,

    /// Force the page backing memory to be an exact-size heap
    /// allocation even if it would fit within a standard-size pool
    /// item. This is used when compacting pages to their minimum
    /// size, since a pool item always retains a full std_size buffer
    /// regardless of the page layout.
    exact_size: bool = false,
};

/// Create a new page node. This does not add it to the list and this
/// does not do any memory size accounting with max_size/page_size.
inline fn createPage(
    self: *PageList,
    opts: CreatePage,
) Allocator.Error!*List.Node {
    // log.debug("create page cap={}", .{opts.cap});

    // If we have a node available for recycling (only during reflow,
    // see recycle_node), reuse it directly rather than going through
    // the memory pool.
    if (self.recycle_node) |node| recycle: {
        // Only a standard pool-owned resident node can be rebuilt
        // in place for a standard-size layout.
        if (opts.exact_size) break :recycle;
        if (node.owned != .pool) break :recycle;
        if (node.data != .resident) break :recycle;
        const layout = Page.layout(opts.cap);
        if (layout.total_size > std_size) break :recycle;

        self.recycle_node = null;

        // The pool guarantees that buffers it hands out are zeroed.
        // A pool-owned page dirties only its Page.memory prefix of
        // the underlying standard-size item, so zeroing that prefix
        // re-establishes the guarantee (this mirrors destroyNodeExt,
        // minus the decommit).
        const page = &node.data.resident;
        const item: *align(std.heap.page_size_min) [std_size]u8 =
            @ptrCast(@alignCast(page.memory.ptr));
        @memset(page.memory, 0);

        // Accounting: a pool-owned node always accounts for a full
        // pool item in page_size, so destroying the node and
        // creating a new pooled one is a net zero.

        node.* = .{
            .data = .{ .resident = .initBuf(.init(item), layout) },
            .serial = self.page_serial,
            .owned = .pool,
        };
        node.page().size.rows = 0;
        self.page_serial += 1;
        return node;
    }

    return try createPageExt(
        &self.pool,
        opts,
        &self.page_serial,
        &self.page_size,
    );
}

inline fn createPageExt(
    pool: *MemoryPool,
    opts: CreatePage,
    serial: *u64,
    total_size: ?*usize,
) Allocator.Error!*List.Node {
    var page = try pool.nodes.create();
    errdefer pool.nodes.destroy(page);

    const layout = Page.layout(opts.cap);
    const pooled = !opts.exact_size and layout.total_size <= std_size;
    const page_alloc = pool.pages.allocator;

    // It would be better to encode this into the Zig error handling
    // system but that is a big undertaking and we only have a few
    // centralized call sites so it is handled on its own currently.
    assert(layout.total_size <= size.max_page_size);

    // Our page buffer comes from our standard memory pool if it
    // is within our standard size since this is what the pool
    // dispenses. Otherwise, we use the heap allocator to allocate.
    const page_buf = if (pooled) buf: {
        const buf = try pool.pages.create();
        terminal_mem.recommit(buf);
        break :buf buf;
    } else try page_alloc.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        layout.total_size,
    );
    errdefer if (pooled)
        pool.pages.destroy(page_buf)
    else
        page_alloc.free(page_buf);

    // In runtime safety modes, allocators fill with 0xAA.
    //
    // Otherwise, we rely on pool item buffers being zeroed: fresh items
    // come from the OS page allocator (zeroed pages), destroyNodeExt
    // zeroes buffers before returning them to the pool, and the pool
    // never writes into its items (see PagePool).
    if (comptime std.debug.runtime_safety)
        @memset(page_buf, 0);

    page.* = .{
        .data = .{ .resident = .initBuf(.init(page_buf), layout) },
        .serial = serial.*,
        .owned = if (pooled) .pool else .heap,
    };
    page.page().size.rows = 0;
    serial.* += 1;

    if (total_size) |v| {
        // Accumulate page size now. We don't assert or check max size
        // because we may exceed it here temporarily as we are allocating
        // pages before destroy.
        v.* += page_buf.len;
    }

    return page;
}

/// Temporary output memory used while creating a compressed page.
///
/// Standard-sized output borrows a page-pool item so repeated compression can
/// reuse the same virtual mapping. Oversized pages use a temporary allocation
/// from the page allocator and release it immediately after compression.
///
/// A borrowed item goes back to the pool through zero-mode decommit, which
/// only has to clear the bytes the encoder wrote. Callers therefore pass the
/// dirty length to `deinit` rather than paying to clear the whole item.
const CompressionScratch = union(enum) {
    pooled: *align(std.heap.page_size_min) [std_size]u8,
    allocated: []align(std.heap.page_size_min) u8,

    fn init(
        pool: *MemoryPool,
        required: usize,
        raw_len: usize,
    ) Allocator.Error!CompressionScratch {
        assert(required <= raw_len);

        if (required <= std_size) {
            const memory = try pool.pages.create();
            terminal_mem.recommit(memory);
            return .{ .pooled = memory };
        }

        const page_alloc = pool.pages.allocator;
        return .{ .allocated = try page_alloc.alignedAlloc(
            u8,
            .fromByteUnits(std.heap.page_size_min),
            raw_len,
        ) };
    }

    fn bytes(self: *CompressionScratch) []u8 {
        return switch (self.*) {
            .pooled => |memory| memory,
            .allocated => |memory| memory,
        };
    }

    fn deinit(
        self: *CompressionScratch,
        pool: *MemoryPool,
        dirty_len: usize,
    ) void {
        switch (self.*) {
            .pooled => |memory| {
                _ = terminal_mem.decommit(.zero, memory, dirty_len);
                pool.pages.destroy(memory);
            },
            .allocated => |memory| {
                const page_alloc = pool.pages.allocator;
                page_alloc.free(memory);
            },
        }
    }
};

/// PageList-owned state for incremental compression.
///
/// The position is stored as a page serial rather than a node pointer so it
/// remains safe when PageList operations destroy, replace, or reuse nodes
/// between steps. It also records the first serial which was unallocated at
/// the prior step so new nodes before a valid marker restart safely. If the
/// exact serial no longer exists in the cold prefix, the next step also
/// restarts at the first page.
///
/// A completed pass is followed by another pass from the oldest cold page.
/// Compression becomes idle only when that verification pass compresses no
/// pages. This converges after pages are restored between incremental steps
/// without requiring consumers to maintain a separate attempt cursor.
const IncrementalCompressionState = struct {
    flags: packed struct {
        /// Set after any page is compressed during the current traversal.
        /// We always run incremental compression until we get a fully
        /// no-compression pass (the verification pass). This lets us
        /// recompress decompressed pages due to search, scrolling, etc.
        did_compress: bool = false,

        /// Set after a traversal first reaches the active boundary. When this
        /// verification traversal reaches the boundary, `did_compress`
        /// determines whether to restart once more or finish the pass.
        verifying: bool = false,
    } = .{},

    /// Changes whenever PageList activity may affect compression work.
    /// Callers use this value (via Terminal.compressionActivity) to
    /// determine whether to recompress.
    ///
    /// The directionality of this doesn't matter. We overflow and
    /// wrap when maxxed. The comparison of this value to your saved
    /// value is all that matters. There is a possible edge case where you
    /// don't compress, a full wraparound happens, and you get the same value,
    /// but its so unlikely.
    ///
    /// This is 48-bits so that 16-bits can be reserved for Terminal to
    /// add extra state.
    activity_serial: u48 = 0,

    /// Serial of the last page inspected by the traversal. This is
    /// intentionally an implementation detail and is reset by PageList
    /// operations which restart traversal progress.
    last_serial: ?u64 = null,

    /// First node serial which had not been allocated at the prior step. A
    /// node at or above this value before the saved marker requires a restart.
    next_serial: u64 = 0,

    /// Record activity without disturbing valid traversal progress.
    fn markActivity(self: *IncrementalCompressionState) void {
        self.activity_serial +%= 1;
    }

    /// Discard traversal progress without changing the activity token.
    fn reset(self: *IncrementalCompressionState) void {
        const activity_serial: u48 = self.activity_serial;
        self.* = .{ .activity_serial = activity_serial };
    }
};

/// Result of one incremental compression step.
pub const IncrementalCompressionResult = enum {
    /// Strict retained-mapping reclamation is unavailable on this target.
    unsupported,

    /// More cold pages or a verification pass remain after this invocation's
    /// candidate-bounded work.
    pending,

    /// A complete verification pass compressed zero pages.
    complete,
};

/// Iterate complete historical pages which do not intersect the viewport.
///
/// All boundaries come from PageList pins and Page metadata. Advancing this
/// iterator never restores a compressed page or reads its backing memory.
const CompressionIterator = struct {
    current: *List.Node,
    active: *List.Node,
    viewport_first: *List.Node,
    viewport_last: *List.Node,

    fn init(self: *const PageList) CompressionIterator {
        return .{
            .current = self.pages.first.?,
            .active = self.getTopLeft(.active).node,
            .viewport_first = self.getTopLeft(.viewport).node,
            .viewport_last = self.getBottomRight(.viewport).?.node,
        };
    }

    fn next(self: *CompressionIterator) ?*List.Node {
        while (self.current != self.active) {
            // The viewport is a contiguous node range. Once traversal reaches
            // its first node, advance through the complete visible range and
            // resume at the next offscreen page.
            if (self.current == self.viewport_first) {
                while (self.current != self.active and
                    self.current != self.viewport_last)
                {
                    self.current = self.current.next.?;
                }

                if (self.current == self.active) return null;
                self.current = self.current.next.?;
                continue;
            }

            const node = self.current;
            self.current = node.next.?;
            return node;
        }

        return null;
    }

    fn done(self: *const CompressionIterator) bool {
        return self.current == self.active;
    }
};

/// Bound candidate inspection independently from compression work. Skipping
/// an already-compressed page is cheap, but still counts toward this limit.
const incremental_compression_max_inspected = 8;

/// Failure injection for the final reclamation step. The operating-system
/// failure path cannot otherwise be exercised by tests because terminal_mem
/// deliberately simulates successful decommit in test builds.
const compressPage_tw = tripwire.module(
    enum { decommit },
    error{DecommitFailed},
);

/// Compress eligible nodes, saving a significant amount of memory.
///
/// Eligible nodes are complete pages before the active boundary which do not
/// intersect the viewport. The boundary page is excluded because it may
/// contain both scrollback and active rows; visible pages remain resident for
/// immediate redraw and scrolling.
///
/// Compression requires a system that supports reclaiming physical memory for
/// virtual allocations while retaining their address ranges.
///
/// Compression is SLOW (relatively), so incremental compression during idle
/// periods is recommended. Incremental mode performs one bounded step and its
/// result specifies whether to continue immediately. Drain mode performs
/// incremental steps until the pass and its verification pass finish. Full
/// mode visits every currently eligible node once without using incremental
/// state.
///
/// PageList tracks mutations which require a later incremental pass in its
/// compression state. On supported targets, full compression returns
/// `complete`, indicating that it has no continuation to schedule rather than
/// that every page was compressed.
pub fn compress(
    self: *PageList,
    mode: enum { incremental, drain, full },
) IncrementalCompressionResult {
    return switch (mode) {
        .incremental => self.compressIncremental(),
        .drain => while (true) switch (self.compressIncremental()) {
            .pending => continue,
            .complete => break .complete,
            .unsupported => break .unsupported,
        },
        .full => full: {
            // Match incremental mode's unsupported result. Full compression
            // has no useful work to perform without strict reclamation.
            if (!terminal_mem.canReclaim(.strict)) {
                self.page_compression.reset();
                break :full .unsupported;
            }

            self.compressFull();

            // Full compression has no continuation. Discard any partial
            // incremental cursor so later activity starts at the oldest page.
            self.page_compression.reset();

            break :full .complete;
        },
    };
}

/// Perform one candidate-bounded incremental cold-history compression step.
fn compressIncremental(self: *PageList) IncrementalCompressionResult {
    const state = &self.page_compression;

    // If we can't reclaim virtual memory, compression is unsupported.
    if (!terminal_mem.canReclaim(.strict)) {
        state.reset();
        return .unsupported;
    }

    // Find the node following the exact continuation marker within the cold
    // prefix. A missing marker means the list changed between steps, so begin
    // again at the current first page. This lookup does not touch page memory.
    var it: CompressionIterator = .init(self);
    if (state.last_serial) |last_serial| continuation: {
        while (it.next()) |node| {
            // A newly allocated or replacement node appeared before the
            // marker. Restart immediately so that node cannot be skipped.
            if (node.serial >= state.next_serial) break;

            // Not a match? Keep looking
            if (node.serial != last_serial) continue;

            // Match! The iterator already points to the next offscreen node.
            break :continuation;
        }

        // Not found or otherwise invalid. Reset
        state.last_serial = null;
        it = .init(self);
    }

    // Keep track of our next_serial
    state.next_serial = self.page_serial;

    // We cap the number of pages we look at to do our best to
    // time-bound the incremental compression.
    var inspected_pages: usize = 0;
    while (inspected_pages < incremental_compression_max_inspected) {
        const node = it.next() orelse break;

        state.last_serial = node.serial;
        inspected_pages += 1;

        // If this page is already compressed, ignore it.
        if (node.isCompressed()) continue;

        // Compression is substantially more expensive even if it fails.
        // So we just try it.
        if (self.compressPage(node)) state.flags.did_compress = true;
        break;
    }

    // If we didn't reach our active node, then we still have work to do.
    if (!it.done()) return .pending;

    // We reached our active node. So we're done, except that we always
    // do one pass after the first success so we can recompress nodes that
    // were possibly decompressed (e.g. by search).
    if (!state.flags.verifying or state.flags.did_compress) {
        const activity_serial: u48 = state.activity_serial;
        state.* = .{
            .flags = .{ .verifying = true },
            .activity_serial = activity_serial,
        };
        return .pending;
    }

    // Leave the state fresh while idle so later activity naturally begins at
    // the oldest cold page, including pages restored after this pass.
    state.reset();
    return .complete;
}

/// Compress every fully historical resident page which is currently cold.
fn compressFull(self: *PageList) void {
    var it: CompressionIterator = .init(self);
    while (it.next()) |node| {

        // Don't restore an already-compressed page just to recompress it.
        if (node.isCompressed()) continue;

        // Failure leaves this node resident and unchanged.
        _ = self.compressPage(node);
    }
}

/// Attempt to compress one resident page while retaining its raw mapping.
///
/// Compression is opportunistic: every failure leaves the page resident and
/// usable. Candidate selection and retry policy belong to `compress`; this
/// primitive only performs one state transition.
fn compressPage(self: *PageList, node: *List.Node) bool {
    // Recompression requires first restoring the raw page and is a policy
    // decision, so this primitive only accepts resident nodes.
    if (node.isCompressed()) return false;

    const page = node.page();

    // The scratch size is capped just below the representation's break-even
    // point. Codec limits and pages too small to cover the compressed-state
    // overhead simply make this page ineligible for compression.
    const required = compression.Page.requiredScratch(page.memory.len) catch |err|
        switch (err) {
            error.InputTooLarge,
            error.OutputTooSmall,
            => return false,
        };
    if (required == 0) return false;

    // Build the compressed candidate without changing the node. This scope is
    // intentional: its defer releases the borrowed or temporary scratch before
    // we attempt to discard the source mapping below. Only the candidate's
    // exact-sized encoded allocation survives the scope.
    const candidate = candidate: {
        var scratch = CompressionScratch.init(
            &self.pool,
            required,
            page.memory.len,
        ) catch |err| switch (err) {
            error.OutOfMemory => return false,
        };

        // The encoder writes at most `required` bytes and reports exactly
        // how many on success. Track that so returning the scratch only
        // clears the prefix it dirtied instead of the whole item.
        var dirty_len: usize = required;
        defer scratch.deinit(&self.pool, dirty_len);

        var table: compression.lz4.HashTable = undefined;
        const result = compression.Page.init(
            self.pool.alloc,
            page,
            scratch.bytes()[0..required],
            &table,
        ) catch |err| switch (err) {
            error.OutOfMemory,
            error.InputTooLarge,
            error.OutputTooSmall,
            => return false,
        };
        if (result) |compressed| dirty_len = compressed.encoded.len;
        break :candidate result;
    };

    // Null means compression crossed the break-even point. The node and its
    // resident mapping are still untouched in this case.
    var compressed = candidate orelse return false;

    // Strict decommit is the final fallible step. It either discards the whole
    // raw mapping or leaves it untouched, so failure can safely free the
    // candidate and preserve the resident node exactly as it was.
    const decommit_allowed: bool = allowed: {
        compressPage_tw.check(.decommit) catch |err| switch (err) {
            error.DecommitFailed => break :allowed false,
        };
        break :allowed true;
    };
    if (!decommit_allowed or !terminal_mem.decommit(
        .strict,
        compressed.page.memory,
        compressed.page.memory.len,
    )) {
        compressed.deinit();
        return false;
    }

    // Publish the new state only after both the encoded allocation and the
    // retained-mapping decommit have succeeded.
    node.data = .{ .compressed = compressed };
    return true;
}

/// Destroy the memory of the given node in the PageList linked list
/// and return it to the pool. The node is assumed to already be removed
/// from the linked list.
///
/// IMPORTANT: This function does NOT update `total_rows`. The caller is
/// responsible for accounting for the removed rows. This function only
/// updates `page_size` (byte accounting), not row accounting.
fn destroyNode(self: *PageList, node: *List.Node) void {
    destroyNodeExt(&self.pool, node, &self.page_size);
}

fn destroyNodeExt(
    pool: *MemoryPool,
    node: *List.Node,
    total_size: ?*usize,
) void {
    const page = node.restore(.discard);

    // Update our accounting for page size. This must mirror what was
    // added at creation time: a pool-owned page always accounts for a
    // full pool item even if its layout is smaller, while a heap-owned
    // page accounts for its exact memory length.
    if (total_size) |v| v.* -= switch (node.owned) {
        .pool => PagePool.item_size,
        .heap => page.memory.len,
    };

    switch (node.owned) {
        .pool => {
            assert(page.memory.len <= std_size);

            // Reset the memory to zero (and decommit it, where
            // supported) so it can be reused.
            const item: *align(std.heap.page_size_min) [std_size]u8 =
                @ptrCast(@alignCast(page.memory.ptr));
            _ = terminal_mem.decommit(.zero, item, page.memory.len);
            pool.pages.destroy(item);
        },

        .heap => {
            const page_alloc = pool.pages.allocator;
            page_alloc.free(page.memory);
        },
    }

    pool.nodes.destroy(node);
}

/// Clone the given source row into the row at `dst_y` of the given
/// node's page, increasing the node's capacity as necessary to fit the
/// source row's managed memory (styles, hyperlinks, etc.).
///
/// Since increasing capacity replaces the node in the page list, the
/// (possibly replaced) node is returned and the caller must use it in
/// place of the old node. The source must NOT be on the given node
/// since the node's page memory may be freed on capacity increase.
fn cloneRowGrowCapacity(
    self: *PageList,
    node: *List.Node,
    dst_y: usize,
    src_page: *Page,
    src_row: *const Row,
) *List.Node {
    assert(src_page != node.page());

    var current = node;
    while (true) {
        const cur_page = current.page();
        const cur_rows = cur_page.rows.ptr(cur_page.memory.ptr);
        cur_page.cloneRowFrom(
            src_page,
            &cur_rows[dst_y],
            src_row,
        ) catch |err| {
            // Adjust our page capacity to make room for what we
            // didn't have space for.
            current = self.increaseCapacity(
                current,
                IncreaseCapacity.forCloneError(err),
            ) catch |e| switch (e) {
                // We can't gracefully recover from either of these
                // here: our callers have already rotated rows, so
                // returning an error would leave the page list
                // half-mutated (and corrupt), so a crash is better.
                error.OutOfMemory,
                => @panic("increaseCapacity system allocator OOM"),

                error.OutOfSpace,
                => @panic("increaseCapacity OutOfSpace"),
            };

            // Retry the row copy with the increased capacity.
            continue;
        };

        return current;
    }
}

/// Fast-path function to erase exactly 1 row. Erasing means that the row
/// is completely REMOVED, not just cleared. All rows following the removed
/// row will be shifted up by 1 to fill the empty space.
///
/// Unlike eraseRows, eraseRow does not change the size of any pages. The
/// caller is responsible for adjusting the row count of the final page if
/// that behavior is required.
pub fn eraseRow(
    self: *PageList,
    pt: point.Point,
) !void {
    defer self.assertIntegrity();
    const pn = self.pin(pt).?;

    var node = pn.node;
    var page = node.page();
    var rows = page.rows.ptr(page.memory.ptr);

    // Erasing history may restore compressed pages. Mark unconditionally
    // because incrementing the activity token is cheaper than locating the
    // active boundary.
    self.page_compression.markActivity();

    // In order to move the following rows up we rotate the rows array by 1.
    // The rotate operation turns e.g. [ 0 1 2 3 ] in to [ 1 2 3 0 ], which
    // works perfectly to move all of our elements where they belong.
    // Rotating rows changes which logical row cached coordinates identify.
    self.invalidateNodeLayout(node);
    fastmem.rotateOnce(Row, rows[pn.y..node.rows()]);

    // We adjust the tracked pins in this page, moving up any that were below
    // the removed row.
    {
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node == node and p.y > pn.y) p.y -= 1;
        }
    }

    // If we have a pinned viewport, we need to adjust for active area.
    self.fixupViewport(1);

    // Mark the whole page as dirty.
    //
    // Technically we only need to mark rows from the erased row to the end
    // of the page as dirty, but that's slower and this is a hot function.
    page.dirty = true;

    // We iterate through all of the following pages in order to move their
    // rows up by 1 as well.
    while (node.next) |next| {
        const next_page = next.page();
        const next_rows = next_page.rows.ptr(next_page.memory.ptr);

        // We take the top row of the page and clone it in to the bottom
        // row of the previous page, which gets rid of the top row that was
        // rotated down in the previous page, and accounts for the row in
        // this page that will be rotated down as well.
        //
        //  rotate -> clone --> rotate -> result
        //    0 -.      1         1         1
        //    1  |      2         2         2
        //    2  |      3         3         3
        //    3 <'      0 <.      4         4
        //   ---       --- |     ---       ---  <- page boundary
        //    4         4 -'      4 -.      5
        //    5         5         5  |      6
        //    6         6         6  |      7
        //    7         7         7 <'      4
        //
        // The copy may replace the destination node in order to
        // increase its capacity. We can discard the replacement
        // because we advance to the next node below, and the
        // replacement is already linked in its place (so e.g. the
        // `node.prev` access in the pin fixups below is correct).
        _ = self.cloneRowGrowCapacity(
            node,
            node.rows() - 1,
            next_page,
            &next_rows[0],
        );

        node = next;
        page = next_page;
        rows = next_rows;

        // Rotating this page moves every cached row coordinate up by one.
        self.invalidateNodeLayout(node);
        fastmem.rotateOnce(Row, rows[0..node.rows()]);

        // Mark the whole page as dirty.
        page.dirty = true;

        // Our tracked pins for this page need to be updated.
        // If the pin is in row 0 that means the corresponding row has
        // been moved to the previous page. Otherwise, move it up by 1.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != node) continue;
            if (p.y == 0) {
                p.node = node.prev.?;
                p.y = p.node.rows() - 1;
                continue;
            }
            p.y -= 1;
        }
    }

    // Reset the final row which was rotated from the top of the page.
    // A full reset (not just clearing cells) so no metadata from the
    // erased row is retained by the new blank row.
    page.resetRow(&rows[node.rows() - 1]);
}

/// A variant of eraseRow that shifts only a bounded number of following
/// rows up, filling the space they leave behind with blank rows.
///
/// `limit` is exclusive of the erased row. A limit of 1 will erase the target
/// row and shift the row below in to its position, leaving a blank row below.
pub fn eraseRowBounded(
    self: *PageList,
    pt: point.Point,
    limit: usize,
) !void {
    defer self.assertIntegrity();

    // This function has a lot of repeated code in it because it is a hot path.
    //
    // To get a better idea of what's happening, read eraseRow first for more
    // in-depth explanatory comments. To avoid repetition, the only comments for
    // this function are for where it differs from eraseRow.

    const pn = self.pin(pt).?;

    var node: *List.Node = pn.node;
    var page = node.page();
    var rows = page.rows.ptr(page.memory.ptr);

    // Erasing history may restore compressed pages. Mark unconditionally
    // because incrementing the activity token is cheaper than locating the
    // active boundary.
    self.page_compression.markActivity();

    // If the row limit is less than the remaining rows before the end of the
    // page, then we clear the row, rotate it to the end of the boundary limit
    // and update our pins.
    if (node.rows() - pn.y > limit) {
        // Rotating this bounded region changes its cached row coordinates.
        self.invalidateNodeLayout(node);
        page.resetRow(&rows[pn.y]);
        fastmem.rotateOnce(Row, rows[pn.y..][0 .. limit + 1]);

        // Mark the whole page as dirty.
        //
        // Technically we only need to mark from the erased row to the
        // limit but this is a hot function, so we want to minimize work.
        page.dirty = true;

        // If our viewport is a pin and our pin is within the erased
        // region we need to maybe shift our cache up. We do this here instead
        // of in the pin loop below because its unlikely to be true and we
        // don't want to run the conditional N times.
        if (self.viewport == .pin) viewport: {
            if (self.viewport_pin_row_offset) |*v| {
                const p = self.viewport_pin;
                if (p.node != node or
                    p.y < pn.y or
                    p.y > pn.y + limit or
                    p.y == 0) break :viewport;
                v.* -= 1;
            }
        }

        // Update pins in the shifted region.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node == node and
                p.y >= pn.y and
                p.y <= pn.y + limit)
            {
                if (p.y == 0) {
                    p.x = 0;
                } else {
                    p.y -= 1;
                }
            }
        }

        return;
    }

    // Rotating this suffix changes which logical row its coordinates identify.
    self.invalidateNodeLayout(node);
    fastmem.rotateOnce(Row, rows[pn.y..node.rows()]);

    // Mark the whole page as dirty.
    //
    // Technically we only need to mark rows from the erased row to the end
    // of the page as dirty, but that's slower and this is a hot function.
    page.dirty = true;

    // We need to keep track of how many rows we've shifted so that we can
    // determine at what point we need to do a partial shift on subsequent
    // pages.
    var shifted: usize = node.rows() - pn.y;

    // Update tracked pins.
    {
        // See the other places we do something similar in this function
        // for a detailed explanation.
        if (self.viewport == .pin) viewport: {
            if (self.viewport_pin_row_offset) |*v| {
                const p = self.viewport_pin;
                if (p.node != node or
                    p.y < pn.y or
                    p.y == 0) break :viewport;
                v.* -= 1;
            }
        }

        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node == node and p.y >= pn.y) {
                if (p.y == 0) {
                    p.x = 0;
                } else {
                    p.y -= 1;
                }
            }
        }
    }

    while (node.next) |next| {
        const next_page = next.page();
        const next_rows = next_page.rows.ptr(next_page.memory.ptr);

        // The copy may replace the destination node in order to
        // increase its capacity. We can discard the replacement
        // because we advance to the next node below, and the
        // replacement is already linked in its place (so e.g. the
        // `node.prev` access in the pin fixups below is correct).
        _ = self.cloneRowGrowCapacity(
            node,
            node.rows() - 1,
            next_page,
            &next_rows[0],
        );

        node = next;
        page = next_page;
        rows = next_rows;

        // We check to see if this page contains enough rows to satisfy the
        // specified limit, accounting for rows we've already shifted in prior
        // pages.
        //
        // The logic here is very similar to the one before the loop.
        const shifted_limit = limit - shifted;
        if (node.rows() > shifted_limit) {
            // Rotating this bounded prefix changes its cached row coordinates.
            self.invalidateNodeLayout(node);
            page.resetRow(&rows[0]);
            fastmem.rotateOnce(Row, rows[0 .. shifted_limit + 1]);

            // Mark the whole page as dirty.
            //
            // Technically we only need to mark from the erased row to the
            // limit but this is a hot function, so we want to minimize work.
            page.dirty = true;

            // See the other places we do something similar in this function
            // for a detailed explanation.
            if (self.viewport == .pin) viewport: {
                if (self.viewport_pin_row_offset) |*v| {
                    const p = self.viewport_pin;
                    if (p.node != node or
                        p.y > shifted_limit) break :viewport;
                    v.* -= 1;
                }
            }

            // Update pins in the shifted region.
            const pin_keys = self.tracked_pins.keys();
            for (pin_keys) |p| {
                if (p.node != node or p.y > shifted_limit) continue;
                if (p.y == 0) {
                    p.node = node.prev.?;
                    p.y = p.node.rows() - 1;
                    continue;
                }
                p.y -= 1;
            }

            return;
        }

        // Rotating the whole page moves every cached row coordinate up by one.
        self.invalidateNodeLayout(node);
        fastmem.rotateOnce(Row, rows[0..node.rows()]);

        // Mark the whole page as dirty.
        page.dirty = true;

        // Account for the rows shifted in this node.
        shifted += node.rows();

        // See the other places we do something similar in this function
        // for a detailed explanation.
        if (self.viewport == .pin) viewport: {
            if (self.viewport_pin_row_offset) |*v| {
                const p = self.viewport_pin;
                if (p.node != node) break :viewport;
                v.* -= 1;
            }
        }

        // Update tracked pins.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != node) continue;
            if (p.y == 0) {
                p.node = node.prev.?;
                p.y = p.node.rows() - 1;
                continue;
            }
            p.y -= 1;
        }
    }

    // We reached the end of the page list before the limit, so we reset
    // the final row since it was rotated down from the top of this page.
    page.resetRow(&rows[node.rows() - 1]);
}

/// Erase all history rows, optionally up to a bottom-left bound.
/// This always starts from the beginning of the history area.
pub fn eraseHistory(
    self: *PageList,
    bl_pt: ?point.Point,
) void {
    self.eraseRows(.{ .history = .{} }, bl_pt);
}

/// Erase active area rows, from the top of the active area to the
/// given row (inclusive).
pub fn eraseActive(
    self: *PageList,
    y: size.CellCountInt,
) void {
    assert(y < self.rows);
    self.eraseRows(.{ .active = .{} }, .{ .active = .{ .y = y } });
}

/// Erase rows from tl_pt to bl_pt (inclusive), physically removing
/// them rather than just clearing their contents. If a point falls
/// in the middle of a page, remaining rows in that page are shifted
/// and the page becomes underutilized (size < capacity).
///
/// Callers must ensure that the erased range only removes pages from
/// the front or back of the linked list, never the middle. The pin and row
/// accounting in this operation is only defined for those boundary ranges.
/// Use the public eraseHistory/eraseActive wrappers which enforce this.
fn eraseRows(
    self: *PageList,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) void {
    defer self.assertIntegrity();
    self.page_compression.markActivity();

    // The count of rows that was erased.
    var erased: usize = 0;

    // A pageIterator iterates one page at a time from the back forward.
    // "back" here is in terms of scrollback, but actually the front of the
    // linked list.
    var it = self.pageIterator(.right_down, tl_pt, bl_pt);
    while (it.next()) |chunk| {
        // If the chunk is a full page, deinit thit page and remove it from
        // the linked list.
        if (chunk.fullPage()) {
            // A rare special case is that we're deleting everything
            // in our linked list. erasePage requires at least one other
            // page so to handle this we reinit this page, set it to zero
            // size which will let us grow our active area back.
            if (chunk.node.next == null and chunk.node.prev == null) {
                // Reinitializing the sole page invalidates every coordinate in it.
                self.invalidateNodeLayout(chunk.node);
                const page = chunk.node.page();
                erased += page.size.rows;
                page.reinit();
                page.size.rows = 0;
                break;
            }

            erased += chunk.node.rows();
            self.erasePage(chunk.node);
            continue;
        }

        // Moving the retained suffix changes every captured row coordinate.
        self.invalidateNodeLayout(chunk.node);

        // We are modifying our chunk so make sure it is in a good state.
        const page = chunk.node.page();
        defer page.assertIntegrity();

        // The chunk is not a full page so we need to move the rows.
        // This is a cheap operation because we're just moving cell offsets,
        // not the actual cell contents.
        assert(chunk.start == 0);
        const rows = page.rows.ptr(page.memory);
        const scroll_amount = chunk.node.rows() - chunk.end;
        for (0..scroll_amount) |i| {
            const src: *Row = &rows[i + chunk.end];
            const dst: *Row = &rows[i];
            const old_dst = dst.*;
            dst.* = src.*;
            src.* = old_dst;

            // Mark the moved row as dirty.
            dst.dirty = true;
        }

        // Reset our remaining rows that we didn't shift or swapped.
        // These are retired into unused page capacity, which the
        // grow() fast path re-exposes without any clearing, so they
        // must be left in the default state.
        for (scroll_amount..chunk.node.rows()) |i| {
            page.resetRow(&rows[i]);
        }

        // Update any tracked pins to shift their y. If it was in the erased
        // row then we move it to the top of this page.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != chunk.node) continue;
            if (p.y >= chunk.end) {
                p.y -= chunk.end;
            } else {
                p.y = 0;
                p.x = 0;
            }
        }

        // Our new size is the amount we scrolled
        page.size.rows = @intCast(scroll_amount);
        erased += chunk.end;
    }

    // Update our total row count
    self.total_rows -= erased;

    // If we deleted active, we need to regrow because one of our invariants
    // is that we always have full active space.
    if (tl_pt == .active) {
        for (0..erased) |_| _ = self.grow() catch |err| {
            // If this fails its a pretty big issue actually... but I don't
            // want to turn this function into an error-returning function
            // because erasing active is so rare and even if it happens failing
            // is even more rare...
            log.err("failed to regrow active area after erase err={}", .{err});
            return;
        };
    }

    // If we have a pinned viewport, we need to adjust for active area.
    self.fixupViewport(erased);
}

/// Erase a single page, freeing all its resources. The page must be
/// at the front or back of the linked list (not the middle) and must
/// NOT be the final page in the entire list (i.e. must not make the
/// list empty).
///
/// IMPORTANT: This function does NOT update `total_rows`. The caller is
/// responsible for accounting for the removed rows before or after calling
/// this function.
fn erasePage(self: *PageList, node: *List.Node) void {
    // Must not be the final page.
    assert(node.next != null or node.prev != null);

    // We only support erasing from the front or back, never the middle. The
    // public erase operations maintain this contract by construction.
    assert(node.prev == null or node.next == null);

    // Update any tracked pins to move to the previous or next page.
    const pin_keys = self.tracked_pins.keys();
    for (pin_keys) |p| {
        if (p.node != node) continue;
        p.node = node.prev orelse node.next orelse unreachable;
        p.y = 0;
        p.x = 0;

        // This doesn't get marked garbage because the tracked pin
        // movement is sensical.
    }

    // Remove the page from the linked list
    self.pages.remove(node);
    self.destroyNode(node);
}

/// Returns the pin for the given point. The pin is NOT tracked so it
/// is only valid as long as the pagelist isn't modified.
///
/// This will return null if the point is out of bounds. The caller
/// should clamp the point to the bounds of the coordinate space if
/// necessary.
pub fn pin(self: *const PageList, pt: point.Point) ?Pin {
    // getTopLeft is much more expensive than checking the cols bounds
    // so we do this first.
    const x = pt.coord().x;
    if (x >= self.cols) return null;

    // Grab the top left and move to the point.
    var p = self.getTopLeft(pt).down(pt.coord().y) orelse return null;
    // Incomplete reflow can leave a page narrower than the desired width.
    // Never manufacture an out-of-bounds pin for that page.
    if (x >= p.node.cols()) return null;
    p.x = x;
    return p;
}

/// Convert the given pin to a tracked pin. A tracked pin will always be
/// automatically updated as the pagelist is modified. If the point the
/// pin points to is removed completely, the tracked pin will be updated
/// to the top-left of the screen.
pub fn trackPin(self: *PageList, p: Pin) Allocator.Error!*Pin {
    if (build_options.slow_runtime_safety) assert(self.pinIsValid(p));

    // Create our tracked pin
    const tracked = try self.pool.pins.create();
    errdefer self.pool.pins.destroy(tracked);
    tracked.* = p;

    // Add it to the tracked list
    try self.tracked_pins.putNoClobber(self.pool.alloc, tracked, {});
    errdefer _ = self.tracked_pins.remove(tracked);

    return tracked;
}

/// Untrack a previously tracked pin. This will deallocate the pin.
pub fn untrackPin(self: *PageList, p: *Pin) void {
    assert(p != self.viewport_pin);
    if (self.tracked_pins.swapRemove(p)) {
        self.pool.pins.destroy(p);
    }
}

pub fn countTrackedPins(self: *const PageList) usize {
    return self.tracked_pins.count();
}

/// Returns the tracked pins for this pagelist. The slice is owned by the
/// pagelist and is only valid until the pagelist is modified.
pub fn trackedPins(self: *const PageList) []const *Pin {
    return self.tracked_pins.keys();
}

/// Checks if a pin is valid for this pagelist. This is a very slow and
/// expensive operation since we traverse the entire linked list in the
/// worst case. Only for runtime safety/debug.
pub fn pinIsValid(self: *const PageList, p: Pin) bool {
    // This is very slow so we want to ensure we only ever
    // call this during slow runtime safety builds.
    comptime assert(build_options.slow_runtime_safety);

    var it = self.pages.first;
    while (it) |node| : (it = node.next) {
        if (node != p.node) continue;
        return p.y < node.rows() and
            p.x < node.cols();
    }

    return false;
}

/// Returns whether a node pointer and serial still identify the same page in
/// this list. The node pointer is only compared and is safe even if the node
/// has been destroyed or reused since the serial was captured.
pub fn nodeIsValid(
    self: *const PageList,
    target: *List.Node,
    serial: u64,
) bool {
    // Reset invalidates the whole prior epoch, so reject those generations
    // without scanning the live list.
    if (serial < self.page_serial_epoch) return false;

    var it = self.pages.first;
    while (it) |node| : (it = node.next) {
        if (node == target) return node.serial == serial;
    }

    return false;
}

/// Returns the viewport for the given pin, preferring to pin to
/// "active" if the pin is within the active area.
fn pinIsActive(self: *const PageList, p: Pin) bool {
    // If the pin is in the active page, then we can quickly determine
    // if we're beyond the end.
    const active = self.getTopLeft(.active);
    if (p.node == active.node) return p.y >= active.y;

    var node_ = active.node.next;
    while (node_) |node| {
        // This loop is pretty fast because the active area is
        // never that large so this is at most one, two nodes for
        // reasonable terminals (including very large real world
        // ones).

        // A node forward in the active area is our node, so we're
        // definitely in the active area.
        if (node == p.node) return true;
        node_ = node.next;
    }

    return false;
}

/// Returns true if the pin is at the top of the scrollback area.
fn pinIsTop(self: *const PageList, p: Pin) bool {
    return p.y == 0 and p.node == self.pages.first.?;
}

/// Convert a pin to a point in the given context. If the pin can't fit
/// within the given tag (i.e. its in the history but you requested active),
/// then this will return null.
///
/// Note that this can be a very expensive operation depending on the tag and
/// the location of the pin. This works by traversing the linked list of pages
/// in the tagged region.
///
/// Therefore, this is recommended only very rarely.
pub fn pointFromPin(self: *const PageList, tag: point.Tag, p: Pin) ?point.Point {
    const tl = self.getTopLeft(tag);

    // Count our first page which is special because it may be partial.
    var coord: point.Coordinate = .{ .x = p.x };
    if (p.node == tl.node) {
        // If our top-left is after our y then we're outside the range.
        if (tl.y > p.y) return null;
        coord.y = p.y - tl.y;
    } else {
        coord.y = std.math.add(
            u32,
            coord.y,
            tl.node.rows() - tl.y,
        ) catch return null;
        var node_ = tl.node.next;
        while (node_) |node| : (node_ = node.next) {
            if (node == p.node) {
                coord.y = std.math.add(u32, coord.y, p.y) catch return null;
                break;
            }

            coord.y = std.math.add(
                u32,
                coord.y,
                node.rows(),
            ) catch return null;
        } else {
            // We never saw our node, meaning we're outside the range.
            return null;
        }
    }

    return switch (tag) {
        inline else => |comptime_tag| @unionInit(
            point.Point,
            @tagName(comptime_tag),
            coord,
        ),
    };
}

/// Get the cell at the given point, or null if the cell does not
/// exist or is out of bounds.
///
/// Warning: this is slow and should not be used in performance critical paths
pub fn getCell(self: *const PageList, pt: point.Point) ?Cell {
    const pt_pin = self.pin(pt) orelse return null;
    const rac = pt_pin.node.page().getRowAndCell(pt_pin.x, pt_pin.y);
    return .{
        .node = pt_pin.node,
        .row = rac.row,
        .cell = rac.cell,
        .row_idx = pt_pin.y,
        .col_idx = pt_pin.x,
    };
}

/// Log a debug diagram of the page list to the provided writer.
///
/// EXAMPLE:
///
///      +-----+ = PAGE 0
///  ... |     |
///   50 | foo |
///  ... |     |
///     +--------+ ACTIVE
///  124 |     | | 0
///  125 |Text | | 1
///      :  ^  : : = PIN 0
///  126 |Wrap…  | 2
///      +-----+ :
///      +-----+ : = PAGE 1
///    0 …ed   | | 3
///    1 | etc.| | 4
///      +-----+ :
///     +--------+
pub fn diagram(
    self: *const PageList,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const active_pin = self.getTopLeft(.active);

    var active = false;
    var active_index: usize = 0;

    var page_index: usize = 0;
    var cols: usize = 0;

    var it = self.pageIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |chunk| : (page_index += 1) {
        cols = chunk.node.cols();

        // Whether we've just skipped some number of rows and drawn
        // an ellipsis row (this is reset when a row is not skipped).
        var skipped = false;

        for (0..chunk.node.rows()) |y| {
            // Active header
            if (!active and
                chunk.node == active_pin.node and
                active_pin.y == y)
            {
                active = true;
                try writer.writeAll("     +-");
                try writer.writeByteNTimes('-', cols);
                try writer.writeAll("--+ ACTIVE");
                try writer.writeByte('\n');
            }

            // Page header
            if (y == 0) {
                try writer.writeAll("      +");
                try writer.writeByteNTimes('-', cols);
                try writer.writeByte('+');
                if (active) try writer.writeAll(" :");
                try writer.print(" = PAGE {}", .{page_index});
                try writer.writeByte('\n');
            }

            // Row contents
            {
                const row = chunk.node.page().getRow(y);
                const cells = chunk.node.page().getCells(row)[0..cols];

                var row_has_content = false;

                for (cells) |cell| {
                    if (cell.hasText()) {
                        row_has_content = true;
                        break;
                    }
                }

                // We don't want to print this row's contents
                // unless it has text or is in the active area.
                if (!active and !row_has_content) {
                    // If we haven't, draw an ellipsis row.
                    if (!skipped) {
                        try writer.writeAll("  ... :");
                        try writer.writeByteNTimes(' ', cols);
                        try writer.writeByte(':');
                        if (active) try writer.writeAll(" :");
                        try writer.writeByte('\n');
                    }
                    skipped = true;
                    continue;
                }

                skipped = false;

                // Left pad row number to 5 wide
                const y_digits = if (y == 0) 0 else std.math.log10_int(y);
                try writer.writeByteNTimes(' ', 4 - y_digits);
                try writer.print("{} ", .{y});

                // Left edge or wrap continuation marker
                try writer.writeAll(if (row.wrap_continuation) "…" else "|");

                // Row text
                if (row_has_content) {
                    for (cells) |*cell| {
                        // Skip spacer tails, since wide cells are, well, wide.
                        if (cell.wide == .spacer_tail) continue;

                        // Write non-printing bytes as base36, for convenience.
                        if (cell.codepoint() < ' ') {
                            try writer.writeByte("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"[cell.codepoint()]);
                            continue;
                        }
                        try writer.print("{u}", .{cell.codepoint()});
                        if (cell.hasGrapheme()) {
                            const grapheme = chunk.node.page().lookupGrapheme(cell).?;
                            for (grapheme) |cp| {
                                try writer.print("{u}", .{cp});
                            }
                        }
                    }
                } else {
                    try writer.writeByteNTimes(' ', cols);
                }

                // Right edge or wrap marker
                try writer.writeAll(if (row.wrap) "…" else "|");
                if (active) {
                    try writer.print(" | {}", .{active_index});
                    active_index += 1;
                }

                try writer.writeByte('\n');
            }

            // Tracked pin marker(s)
            pins: {
                // If we have more than 16 tracked pins in a row, oh well,
                // don't wanna bother making this function allocating.
                var pin_buf: [16]*Pin = undefined;
                var pin_count: usize = 0;
                const pin_keys = self.tracked_pins.keys();
                for (pin_keys) |p| {
                    if (p.node != chunk.node) continue;
                    if (p.y != y) continue;
                    pin_buf[pin_count] = p;
                    pin_count += 1;
                    if (pin_count >= pin_buf.len) return error.TooManyTrackedPinsInRow;
                }

                if (pin_count == 0) break :pins;

                const pins = pin_buf[0..pin_count];
                std.mem.sort(
                    *Pin,
                    pins,
                    {},
                    struct {
                        fn lt(_: void, a: *Pin, b: *Pin) bool {
                            return a.x < b.x;
                        }
                    }.lt,
                );

                try writer.writeAll("      :");
                var x: usize = 0;

                for (pins) |p| {
                    if (x > p.x) continue;
                    try writer.writeByteNTimes(' ', p.x - x);
                    try writer.writeByte('^');
                    x = p.x + 1;
                }

                try writer.writeByteNTimes(' ', cols - x);
                try writer.writeByte(':');

                if (active) try writer.writeAll(" :");

                try writer.print(" = PIN{s}", .{if (pin_count > 1) "S" else ""});

                x = pins[0].x;
                for (pins, 0..) |p, i| {
                    if (p.x != x) try writer.writeByte(',');
                    try writer.print(" {}", .{i});
                }

                try writer.writeByte('\n');
            }
        }

        // Page footer
        {
            try writer.writeAll("      +");
            try writer.writeByteNTimes('-', cols);
            try writer.writeByte('+');
            if (active) try writer.writeAll(" :");
            try writer.writeByte('\n');
        }
    }

    // Active footer
    {
        try writer.writeAll("     +-");
        try writer.writeByteNTimes('-', cols);
        try writer.writeAll("--+");
        try writer.writeByte('\n');
    }
}

/// Returns the boundaries of the given semantic content type for
/// the prompt at the given pin. The pin row MUST be the first row
/// of a prompt, otherwise the results may be nonsense.
///
/// To get prompt pins, use promptIterator. Warning that if there are
/// no semantic prompts ever present, promptIterator will iterate the
/// entire PageList. Downstream callers should keep track of a flag if
/// they've ever seen semantic prompt operations to prevent this performance
/// case.
///
/// Note that some semantic content type such as "input" is usually
/// nested within prompt boundaries, so the returned boundaries may include
/// prompt text.
pub fn highlightSemanticContent(
    self: *const PageList,
    at: Pin,
    content: pagepkg.Cell.SemanticContent,
) ?highlight.Untracked {
    // Performance note: we can do this more efficiently in a single
    // forward-pass. Semantic content operations aren't usually fast path
    // but if someone wants to optimize them someday that's great.

    const end: Pin = end: {
        // Safety assertion, our starting point should be a prompt row.
        // so the first returned prompt should be ourselves.
        var it = at.promptIterator(.right_down, null);
        assert(it.next().?.y == at.y);

        // Our end is the end of the line just before the next prompt
        // line, which should exist since we verified we have at least
        // two prompts here.
        if (it.next()) |next| next: {
            var prev = next.up(1) orelse break :next;
            prev.x = prev.node.cols() - 1;
            break :end prev;
        }

        // Didn't find any further prompt so the end of our zone is
        // the end of the screen.
        break :end self.getBottomRight(.screen).?;
    };

    switch (content) {
        // For the prompt, we select all the way up to command output.
        // We include all the input lines, too.
        .prompt => {
            var result: highlight.Untracked = .{
                .start = at.left(at.x),
                .end = at,
            };

            var it = at.cellIterator(.right_down, end);
            while (it.next()) |p| {
                switch (p.rowAndCell().cell.semantic_content) {
                    .prompt, .input => result.end = p,
                    .output => break,
                }
            }

            return result;
        },

        // For input, we include the start of the input to the end of
        // the input, which may include all the prompts in the middle, too.
        .input => {
            var result: highlight.Untracked = .{
                .start = undefined,
                .end = undefined,
            };

            // Find the start
            var it = at.cellIterator(.right_down, end);
            while (it.next()) |p| {
                switch (p.rowAndCell().cell.semantic_content) {
                    .prompt => {},
                    .input => {
                        result.start = p;
                        result.end = p;
                        break;
                    },
                    .output => return null,
                }
            } else {
                // No input found
                return null;
            }

            // Find the end
            while (it.next()) |p| {
                switch (p.rowAndCell().cell.semantic_content) {
                    // Prompts can be nested in our input for continuation
                    .prompt => {},

                    // Output means we're done
                    .output => break,

                    .input => result.end = p,
                }
            }

            return result;
        },

        .output => {
            var result: highlight.Untracked = .{
                .start = undefined,
                .end = undefined,
            };

            // Find the start
            var it = at.cellIterator(.right_down, end);
            while (it.next()) |p| {
                const cell = p.rowAndCell().cell;
                switch (cell.semantic_content) {
                    .prompt, .input => {},
                    .output => {
                        // Skip empty cells - they default to .output but aren't real output
                        if (!cell.hasText()) continue;
                        result.start = p;
                        result.end = p;
                        break;
                    },
                }
            } else {
                // No output found
                return null;
            }

            // Find the end
            while (it.next()) |p| {
                const cell = p.rowAndCell().cell;
                switch (cell.semantic_content) {
                    .prompt, .input => break,
                    .output => {
                        // Only extend to cells with actual text
                        if (cell.hasText()) result.end = p;
                    },
                }
            }

            return result;
        },
    }
}

/// Direction that iterators can move.
pub const Direction = enum { left_up, right_down };

pub const PromptIterator = struct {
    /// The pin that we are currently at. Also the starting pin when
    /// initializing.
    current: ?Pin,

    /// The pin to end at or null if we end when we can't traverse
    /// anymore.
    limit: ?Pin,

    /// The direction to do the traversal.
    direction: Direction,

    pub const empty: PromptIterator = .{
        .current = null,
        .limit = null,
        .direction = .left_up,
    };

    /// Return the next pin that represents the first row in a prompt.
    /// From here, you can find the prompt input, command output, etc.
    pub fn next(self: *PromptIterator) ?Pin {
        switch (self.direction) {
            .left_up => return self.nextLeftUp(),
            .right_down => return self.nextRightDown(),
        }
    }

    pub fn nextRightDown(self: *PromptIterator) ?Pin {
        // Start at our current pin. If we have no current it means
        // we reached the end and we're done.
        const start: Pin = self.current orelse return null;

        // We need to traverse downwards and look for prompts.
        var current: ?Pin = start;
        while (current) |p| : (current = p.down(1)) {
            // Check our limit.
            const at_limit = if (self.limit) |limit| limit.eql(p) else false;

            const rac = p.rowAndCell();
            switch (rac.row.semantic_prompt) {
                // This row isn't a prompt. Keep looking.
                .none => if (at_limit) break,

                // This is a prompt line or continuation line. In either
                // case we consider the first line the prompt, and then
                // skip over any remaining prompt lines. This handles the
                // case where scrollback pruned the prompt.
                .prompt, .prompt_continuation => {
                    // If we're at our limit just return this prompt.
                    if (at_limit) {
                        self.current = null;
                        return p.left(p.x);
                    }

                    // Skip over any continuation lines that follow this prompt,
                    // up to our limit.
                    var end_pin = p;
                    while (end_pin.down(1)) |next_pin| : (end_pin = next_pin) {
                        switch (next_pin.rowAndCell().row.semantic_prompt) {
                            .prompt_continuation => if (self.limit) |limit| {
                                if (limit.eql(next_pin)) break;
                            },

                            .prompt, .none => {
                                self.current = next_pin;
                                return p.left(p.x);
                            },
                        }
                    }

                    self.current = null;
                    return p.left(p.x);
                },
            }
        }

        self.current = null;
        return null;
    }

    pub fn nextLeftUp(self: *PromptIterator) ?Pin {
        // Start at our current pin. If we have no current it means
        // we reached the end and we're done.
        const start: Pin = self.current orelse return null;

        // We need to traverse upwards and look for prompts.
        var current: ?Pin = start;
        while (current) |p| : (current = p.up(1)) {
            // Check our limit.
            const at_limit = if (self.limit) |limit| limit.eql(p) else false;

            const rac = p.rowAndCell();
            switch (rac.row.semantic_prompt) {
                // This row isn't a prompt. Keep looking.
                .none => if (at_limit) break,

                // This is a prompt line.
                .prompt => {
                    self.current = if (at_limit) null else p.up(1);
                    return p.left(p.x);
                },

                // If this is a prompt continuation, then we continue
                // looking for the start of the prompt OR a non-prompt
                // line, whichever is first. The non-prompt line is to handle
                // poorly behaved programs or scrollback that's been cut-off.
                .prompt_continuation => {
                    // If we're at our limit just return this continuation as prompt.
                    if (at_limit) {
                        self.current = null;
                        return p.left(p.x);
                    }

                    var end_pin = p;
                    while (end_pin.up(1)) |prior| : (end_pin = prior) {
                        if (self.limit) |limit| {
                            if (limit.eql(prior)) break;
                        }

                        switch (prior.rowAndCell().row.semantic_prompt) {
                            // No prompt. That means our last pin is good!
                            .none => {
                                self.current = prior;
                                return end_pin.left(end_pin.x);
                            },

                            // Prompt continuation, keep looking.
                            .prompt_continuation => {},

                            // Prompt! Found it!
                            .prompt => {
                                self.current = prior.up(1);
                                return prior.left(prior.x);
                            },
                        }
                    }

                    // No prior rows, trimmed scrollback probably.
                    self.current = null;
                    return p.left(p.x);
                },
            }
        }

        self.current = null;
        return null;
    }
};

pub fn promptIterator(
    self: *const PageList,
    direction: Direction,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) PromptIterator {
    const tl_pin = self.pin(tl_pt).?;
    const bl_pin = if (bl_pt) |pt|
        self.pin(pt).?
    else
        self.getBottomRight(tl_pt) orelse return .empty;

    return switch (direction) {
        .right_down => tl_pin.promptIterator(.right_down, bl_pin),
        .left_up => bl_pin.promptIterator(.left_up, tl_pin),
    };
}

pub const CellIterator = struct {
    row_it: RowIterator,
    cell: ?Pin = null,

    pub fn next(self: *CellIterator) ?Pin {
        const cell = self.cell orelse return null;

        switch (self.row_it.page_it.direction) {
            .right_down => {
                if (cell.x + 1 < cell.node.cols()) {
                    // We still have cells in this row, increase x.
                    var copy = cell;
                    copy.x += 1;
                    self.cell = copy;
                } else {
                    // We need to move to the next row.
                    self.cell = self.row_it.next();
                }
            },

            .left_up => {
                if (cell.x > 0) {
                    // We still have cells in this row, decrease x.
                    var copy = cell;
                    copy.x -= 1;
                    self.cell = copy;
                } else {
                    // We need to move to the previous row and last col
                    if (self.row_it.next()) |next_cell| {
                        var copy = next_cell;
                        copy.x = next_cell.node.cols() - 1;
                        self.cell = copy;
                    } else {
                        self.cell = null;
                    }
                }
            },
        }

        return cell;
    }
};

pub fn cellIterator(
    self: *const PageList,
    direction: Direction,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) CellIterator {
    const tl_pin = self.pin(tl_pt).?;
    const bl_pin = if (bl_pt) |pt|
        self.pin(pt).?
    else
        self.getBottomRight(tl_pt) orelse
            return .{ .row_it = undefined };

    return switch (direction) {
        .right_down => tl_pin.cellIterator(.right_down, bl_pin),
        .left_up => bl_pin.cellIterator(.left_up, tl_pin),
    };
}

pub const RowIterator = struct {
    page_it: PageIterator,
    chunk: ?PageIterator.Chunk = null,
    offset: size.CellCountInt = 0,

    pub fn next(self: *RowIterator) ?Pin {
        const chunk = self.chunk orelse return null;
        const row: Pin = .{ .node = chunk.node, .y = self.offset };

        switch (self.page_it.direction) {
            .right_down => {
                // Increase our offset in the chunk
                self.offset += 1;

                // If we are beyond the chunk end, we need to move to the next chunk.
                if (self.offset >= chunk.end) {
                    self.chunk = self.page_it.next();
                    if (self.chunk) |c| self.offset = c.start;
                }
            },

            .left_up => {
                // If we are at the start of the chunk, we need to move to the
                // previous chunk.
                if (self.offset == 0) {
                    self.chunk = self.page_it.next();
                    if (self.chunk) |c| self.offset = c.end - 1;
                } else {
                    // If we're at the start of the chunk and its a non-zero
                    // offset then we've reached a limit.
                    if (self.offset == chunk.start) {
                        self.chunk = null;
                    } else {
                        self.offset -= 1;
                    }
                }
            },
        }

        return row;
    }
};

/// Create an iterator that can be used to iterate all the rows in
/// a region of the screen from the given top-left. The tag of the
/// top-left point will also determine the end of the iteration,
/// so convert from one reference point to another to change the
/// iteration bounds.
pub fn rowIterator(
    self: *const PageList,
    direction: Direction,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) RowIterator {
    const tl_pin = self.pin(tl_pt).?;
    const bl_pin = if (bl_pt) |pt|
        self.pin(pt).?
    else
        self.getBottomRight(tl_pt) orelse
            return .{ .page_it = undefined };

    return switch (direction) {
        .right_down => tl_pin.rowIterator(.right_down, bl_pin),
        .left_up => bl_pin.rowIterator(.left_up, tl_pin),
    };
}

pub const PageIterator = struct {
    row: ?Pin = null,
    limit: Limit = .none,
    direction: Direction = .right_down,

    const Limit = union(enum) {
        none,
        count: usize,
        row: Pin,
    };

    pub fn next(self: *PageIterator) ?Chunk {
        return switch (self.direction) {
            .left_up => self.nextUp(),
            .right_down => self.nextDown(),
        };
    }

    fn nextDown(self: *PageIterator) ?Chunk {
        // Get our current row location
        const row = self.row orelse return null;

        return switch (self.limit) {
            .none => none: {
                // If we have no limit, then we consume this entire page. Our
                // next row is the next page.
                self.row = next: {
                    const next_page = row.node.next orelse break :next null;
                    break :next .{ .node = next_page };
                };

                break :none .{
                    .node = row.node,
                    .start = row.y,
                    .end = row.node.rows(),
                };
            },

            .count => |*limit| count: {
                assert(limit.* > 0); // should be handled already
                const available: usize = row.node.rows() - row.y;
                const len = @min(available, limit.*);
                limit.* -= len;
                self.row = if (limit.* > 0) row.down(len) else null;

                break :count .{
                    .node = row.node,
                    .start = row.y,
                    .end = @intCast(@as(usize, row.y) + len),
                };
            },

            .row => |limit_row| row: {
                // If this is not the same page as our limit then we
                // can consume the entire page.
                if (limit_row.node != row.node) {
                    self.row = next: {
                        const next_page = row.node.next orelse break :next null;
                        break :next .{ .node = next_page };
                    };

                    break :row .{
                        .node = row.node,
                        .start = row.y,
                        .end = row.node.rows(),
                    };
                }

                // If this is the same page then we only consume up to
                // the limit row.
                self.row = null;
                if (row.y > limit_row.y) return null;
                break :row .{
                    .node = row.node,
                    .start = row.y,
                    .end = limit_row.y + 1,
                };
            },
        };
    }

    fn nextUp(self: *PageIterator) ?Chunk {
        // Get our current row location
        const row = self.row orelse return null;

        return switch (self.limit) {
            .none => none: {
                // If we have no limit, then we consume this entire page. Our
                // next row is the next page.
                self.row = next: {
                    const next_page = row.node.prev orelse break :next null;
                    break :next .{
                        .node = next_page,
                        .y = next_page.rows() - 1,
                    };
                };

                break :none .{
                    .node = row.node,
                    .start = 0,
                    .end = row.y + 1,
                };
            },

            .count => |*limit| count: {
                assert(limit.* > 0); // should be handled already
                const available: usize = @as(usize, row.y) + 1;
                const len = @min(available, limit.*);
                limit.* -= len;
                self.row = if (limit.* > 0) row.up(len) else null;

                break :count .{
                    .node = row.node,
                    .start = @intCast(available - len),
                    .end = @intCast(available),
                };
            },

            .row => |limit_row| row: {
                // If this is not the same page as our limit then we
                // can consume the entire page.
                if (limit_row.node != row.node) {
                    self.row = next: {
                        const next_page = row.node.prev orelse break :next null;
                        break :next .{
                            .node = next_page,
                            .y = next_page.rows() - 1,
                        };
                    };

                    break :row .{
                        .node = row.node,
                        .start = 0,
                        .end = row.y + 1,
                    };
                }

                // If this is the same page then we only consume up to
                // the limit row.
                self.row = null;
                if (row.y < limit_row.y) return null;
                break :row .{
                    .node = row.node,
                    .start = limit_row.y,
                    .end = row.y + 1,
                };
            },
        };
    }

    pub const Chunk = struct {
        node: *List.Node,

        /// Start y index (inclusive) of this chunk in the page.
        start: size.CellCountInt,

        /// End y index (exclusive) of this chunk in the page.
        end: size.CellCountInt,

        pub fn rows(self: Chunk) []Row {
            const page = self.node.page();
            const rows_ptr = page.rows.ptr(page.memory);
            return rows_ptr[self.start..self.end];
        }

        /// Returns true if this chunk represents every row in the page.
        pub fn fullPage(self: Chunk) bool {
            return self.start == 0 and self.end == self.node.rows();
        }

        /// Returns true if this chunk overlaps with the given other chunk
        /// in any way.
        pub fn overlaps(self: Chunk, other: Chunk) bool {
            if (self.node != other.node) return false;
            if (self.end <= other.start) return false;
            if (self.start >= other.end) return false;
            return true;
        }
    };
};

/// Return an iterator that iterates through the rows in the tagged area
/// of the point. The iterator returns row "chunks", which are the largest
/// contiguous set of rows in a single backing page for a given portion of
/// the point region.
///
/// This is a more efficient way to iterate through the data in a region,
/// since you can do simple pointer math and so on.
///
/// If bl_pt is non-null, iteration will stop at the bottom left point
/// (inclusive). If bl_pt is null, the entire region specified by the point
/// tag will be iterated over. tl_pt and bl_pt must be the same tag, and
/// bl_pt must be greater than or equal to tl_pt.
///
/// If direction is left_up, iteration will go from bl_pt to tl_pt. If
/// direction is right_down, iteration will go from tl_pt to bl_pt.
/// Both inclusive.
pub fn pageIterator(
    self: *const PageList,
    direction: Direction,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) PageIterator {
    const tl_pin = self.pin(tl_pt).?;
    const bl_pin = if (bl_pt) |pt|
        self.pin(pt).?
    else
        self.getBottomRight(tl_pt) orelse return .{ .row = null };

    if (build_options.slow_runtime_safety) {
        assert(tl_pin.eql(bl_pin) or tl_pin.before(bl_pin));
    }

    return switch (direction) {
        .right_down => tl_pin.pageIterator(.right_down, bl_pin),
        .left_up => bl_pin.pageIterator(.left_up, tl_pin),
    };
}

/// Get the top-left of the screen for the given tag.
pub fn getTopLeft(self: *const PageList, tag: point.Tag) Pin {
    return switch (tag) {
        // The full screen or history is always just the first page.
        .screen, .history => .{ .node = self.pages.first.? },

        .viewport => switch (self.viewport) {
            .active => self.getTopLeft(.active),
            .top => self.getTopLeft(.screen),
            .pin => self.viewport_pin.*,
        },

        // The active area is calculated backwards from the last page.
        // This makes getting the active top left slower but makes scrolling
        // much faster because we don't need to update the top left. Under
        // heavy load this makes a measurable difference.
        .active => active: {
            var rem = self.rows;
            var it = self.pages.last;
            while (it) |node| : (it = node.prev) {
                if (rem <= node.rows()) break :active .{
                    .node = node,
                    .y = node.rows() - rem,
                };

                rem -= node.rows();
            }

            unreachable; // assertion: we always have enough rows for active
        },
    };
}

/// Returns the bottom right of the screen for the given tag. This can
/// return null because it is possible that a tag is not in the screen
/// (e.g. history does not yet exist).
pub fn getBottomRight(self: *const PageList, tag: point.Tag) ?Pin {
    return switch (tag) {
        .screen, .active => last: {
            const node = self.pages.last.?;
            break :last .{
                .node = node,
                .y = node.rows() - 1,
                .x = node.cols() - 1,
            };
        },

        .viewport => viewport: {
            var br = self.getTopLeft(.viewport);
            br = br.down(self.rows - 1).?;
            br.x = br.node.cols() - 1;
            break :viewport br;
        },

        .history => active: {
            var br = self.getTopLeft(.active);
            br = br.up(1) orelse return null;
            br.x = br.node.cols() - 1;
            break :active br;
        },
    };
}

/// The total rows in the screen. This is the actual row count currently
/// and not a capacity or maximum.
///
/// This is very slow, it traverses the full list of pages to count the
/// rows, so it is not pub. This is only used for testing/debugging.
fn totalRows(self: *const PageList) usize {
    var rows: usize = 0;
    var node_ = self.pages.first;
    while (node_) |node| {
        rows += node.rows();
        node_ = node.next;
    }

    return rows;
}

/// The total number of pages in this list. This should only be used
/// for tests since it is O(N) over the list of pages.
pub fn totalPages(self: *const PageList) usize {
    var pages: usize = 0;
    var node_ = self.pages.first;
    while (node_) |node| {
        pages += 1;
        node_ = node.next;
    }

    return pages;
}

/// Snapshot of the storage used by page nodes in this list.
///
/// The raw byte counts describe page backing mappings only. They exclude
/// nodes, allocator metadata, unused preheated pool items, and the small
/// representation values stored in each node. A compressed page retains its
/// raw mapping as virtual address space, but its bytes are counted as
/// decommitted because strict reclamation succeeded before the state was
/// published.
pub const MemoryStats = struct {
    /// Pages whose raw backing mappings are resident.
    resident_pages: usize = 0,

    /// Pages represented by encoded storage and a decommitted raw mapping.
    compressed_pages: usize = 0,

    /// Logical bytes in every raw page mapping.
    raw_bytes: usize = 0,

    /// Raw mapping bytes which remain resident.
    resident_raw_bytes: usize = 0,

    /// Raw mapping bytes discarded for compressed pages.
    decommitted_raw_bytes: usize = 0,

    /// Raw allocation bytes which remain physically resident.
    ///
    /// This can exceed `resident_raw_bytes` because a pool-owned page uses
    /// only part of a standard pool item. Compressing such a page decommits
    /// its initialized range, but the unused tail of the item stays resident.
    resident_backing_bytes: usize = 0,

    /// Exact encoded allocations retained for compressed pages.
    encoded_bytes: usize = 0,

    /// Estimate resident page backing storage after compression.
    pub fn estimatedResidentBytes(self: MemoryStats) usize {
        return self.resident_backing_bytes + self.encoded_bytes;
    }

    /// Estimate physical bytes avoided by compressed page backing storage.
    pub fn estimatedSavings(self: MemoryStats) usize {
        return self.decommitted_raw_bytes -| self.encoded_bytes;
    }
};

/// Return a metadata-only snapshot of page backing storage.
///
/// This never restores compressed pages. It is intended for diagnostics and
/// other infrequent reporting because it traverses the complete page list.
pub fn memoryStats(self: *const PageList) MemoryStats {
    var result: MemoryStats = .{};
    var current = self.pages.first;
    while (current) |node| : (current = node.next) {
        const raw_len = node.metadata().memory.len;
        const backing_len = switch (node.owned) {
            .pool => PagePool.item_size,
            .heap => raw_len,
        };
        assert(backing_len >= raw_len);
        result.raw_bytes += raw_len;

        switch (node.data) {
            .resident => {
                result.resident_pages += 1;
                result.resident_raw_bytes += raw_len;
                result.resident_backing_bytes += backing_len;
            },

            .compressed => |compressed| {
                result.compressed_pages += 1;
                result.decommitted_raw_bytes += raw_len;
                // Strict reclamation covers only Page.memory. A standard pool
                // item can have an unused tail which remains resident.
                result.resident_backing_bytes += backing_len - raw_len;
                result.encoded_bytes += compressed.encoded.len;
            },
        }
    }

    return result;
}

/// Grow the number of rows available in the page list by n.
/// This is only used for testing so it isn't optimized in any way.
fn growRows(self: *PageList, n: usize) Allocator.Error!void {
    for (0..n) |_| _ = try self.grow();
}

/// Clear all dirty bits on all pages. This is not efficient since it
/// traverses the entire list of pages. This is used for testing/debugging.
pub fn clearDirty(self: *PageList) void {
    var page = self.pages.first;
    while (page) |p| : (page = p.next) {
        const current_page = p.page();
        current_page.dirty = false;
        for (current_page.rows.ptr(current_page.memory)[0..p.rows()]) |*row| {
            row.dirty = false;
        }
    }
}

/// Returns true if the point is dirty, used for testing.
pub fn isDirty(self: *const PageList, pt: point.Point) bool {
    return self.getCell(pt).?.isDirty();
}

/// Mark a point as dirty, used for testing.
fn markDirty(self: *PageList, pt: point.Point) void {
    self.pin(pt).?.markDirty();
}

/// Runtime-configurable byte and line limits for a PageList.
const Limits = struct {
    bytes: Limit,
    lines: Limit,

    /// The limit keys.
    pub const Key = std.meta.FieldEnum(Limits);

    pub const Limit = struct {
        /// Explicit is the specified maximum value for this limit
        /// by the user or maxInt otherwise.
        explicit: usize = std.math.maxInt(usize),

        /// Min is the minimum valid maximum for this entry, so if
        /// explicit is lower than this then min wins.
        min: usize,
    };

    /// Return unlimited limits with minimums for the given PageList size.
    pub fn init(cols: size.CellCountInt, rows: size.CellCountInt) Limits {
        return .{
            .bytes = .{ .min = minMaxSize(cols, rows) },
            .lines = .{ .min = minMaxLines(cols) },
        };
    }

    /// Set an explicit limit. Null means unlimited. This does not enforce the
    /// new value automatically; the caller must still call `enforce`.
    pub fn set(
        self: *Limits,
        comptime key: Key,
        value: ?usize,
    ) void {
        switch (key) {
            .bytes => self.bytes.explicit = value orelse std.math.maxInt(usize),
            .lines => self.lines.explicit = value orelse std.math.maxInt(usize),
        }
    }

    /// Recalculate the effective minimums for a new PageList size.
    ///
    /// This must be called whenever either PageList dimension changes so the
    /// effective byte and line limits remain valid for the new size.
    pub fn resize(
        self: *Limits,
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    ) void {
        self.bytes.min = minMaxSize(cols, rows);
        self.lines.min = minMaxLines(cols);
    }

    /// Return the effective maximum for a limit.
    pub fn max(self: *const Limits, key: Key) usize {
        return switch (key) {
            .bytes => @max(self.bytes.explicit, self.bytes.min),
            .lines => @max(self.lines.explicit, self.lines.min),
        };
    }

    /// Whether the given limit is currently exceeded. Both limits are
    /// heuristics: complete historical pages are the smallest unit that
    /// enforcement removes.
    pub fn exceeded(
        self: *const Limits,
        pagelist: *const PageList,
        limit: Key,
    ) bool {
        return switch (limit) {
            .bytes => pagelist.page_size > self.max(.bytes),
            .lines => pagelist.total_rows > pagelist.rows and
                pagelist.total_rows - pagelist.rows > self.max(.lines),
        };
    }

    /// Prune complete historical pages until the selected limit is satisfied
    /// or the oldest remaining page overlaps the active area.
    pub fn enforce(
        self: *const Limits,
        pagelist: *PageList,
        key: Key,
    ) void {
        if (!self.exceeded(pagelist, key)) return;

        // A partially constructed clone can temporarily contain fewer rows than
        // its active area. It has no scrollback to prune.
        if (pagelist.total_rows <= pagelist.rows) return;

        // Accumulate the row delta so viewport offsets are fixed up once
        // after all eligible pages have been removed.
        var removed: usize = 0;
        while (self.exceeded(pagelist, key)) {
            const first = pagelist.pages.first.?;

            // The page containing the active top may also contain history. Keep
            // that boundary page whole even if its history exceeds the heuristic.
            if (first == pagelist.getTopLeft(.active).node) break;

            if (removed == 0) pagelist.page_compression.markActivity();

            const first_rows = first.rows();

            // Automatic pruning invalidates the content represented by pins in
            // the removed page. erasePage remaps them to the next page below but
            // only the enforcing caller knows that their original content is gone,
            // so mark them as garbage here.
            for (pagelist.tracked_pins.keys()) |p| {
                if (p.node == first) p.garbage = true;
            }

            // erasePage updates the list, pin targets, and byte accounting.
            // Row accounting belongs to the caller because erasePage is also used
            // by paths that already adjusted total_rows.
            pagelist.erasePage(first);
            pagelist.total_rows -= first_rows;
            removed += first_rows;
        }

        // Reconcile viewport mode and cached row offsets with the combined prefix
        // removal only after every page and pin points into the final list.
        if (removed > 0) pagelist.fixupViewport(removed);
    }

    /// Returns the minimum valid "max size" for a given number of rows and cols
    /// such that we can fit the active area AND at least two pages. Note we
    /// need the two pages for algorithms to work properly (such as grow) but
    /// we don't need to fit double the active area.
    ///
    /// This min size may not be totally correct in the case that a large
    /// number of other dimensions makes our row size in a page very small.
    /// But this gives us a nice fast heuristic for determining min/max size.
    /// Therefore, if the page size is violated you should always also verify
    /// that we have enough space for the active area.
    fn minMaxSize(cols: size.CellCountInt, rows: size.CellCountInt) usize {
        // Invariant required to ensure our divCeil below cannot overflow.
        comptime {
            const max_rows = std.math.maxInt(size.CellCountInt);
            _ = std.math.divCeil(usize, max_rows, 1) catch unreachable;
        }

        // Get our capacity to fit our rows. If the cols are too big, it may
        // force less rows than we want meaning we need more than one page to
        // represent a viewport.
        const cap = initialCapacity(cols);

        // Calculate the number of standard sized pages we need to represent
        // an active area.
        const pages_exact = if (cap.rows >= rows) 1 else std.math.divCeil(
            usize,
            rows,
            cap.rows,
        ) catch {
            // Not possible:
            // - initialCapacity guarantees at least 1 row
            // - numerator/denominator can't overflow because of comptime check above
            unreachable;
        };

        // We always need at least one page extra so that we
        // can fit partial pages to spread our active area across two pages.
        // Even for caps that can't fit all rows in a single page, we add one
        // because the most extra space we need at any given time is only
        // the partial amount of one page.
        const pages = pages_exact + 1;
        assert(pages >= 2);

        // log.debug("minMaxSize cols={} rows={} cap={} pages={}", .{
        //     cols,
        //     rows,
        //     cap,
        //     pages,
        // });

        return PagePool.item_size * pages;
    }

    /// Returns the minimum line limit for a given column count. Line limits are
    /// page-granular, so we always permit at least one standard page worth of
    /// scrollback rows.
    fn minMaxLines(cols: size.CellCountInt) usize {
        return initialCapacity(cols).rows;
    }
};

/// Represents an exact x/y coordinate within the screen. This is called
/// a "pin" because it is a fixed point within the pagelist direct to
/// a specific page pointer and memory offset. The benefit is that this
/// point remains valid even through scrolling without any additional work.
///
/// A downside is that  the pin is only valid until the pagelist is modified
/// in a way that may invalidate page pointers or shuffle rows, such as resizing,
/// erasing rows, etc.
///
/// A pin can also be "tracked" which means that it will be updated as the
/// PageList is modified.
///
/// The PageList maintains a list of active pin references and keeps them
/// all up to date as the pagelist is modified. This isn't cheap so callers
/// should limit the number of active pins as much as possible.
pub const Pin = @import("pagelist/Pin.zig");

pub const Cell = struct {
    node: *List.Node,
    row: *pagepkg.Row,
    cell: *pagepkg.Cell,
    row_idx: size.CellCountInt,
    col_idx: size.CellCountInt,

    /// Returns true if this cell is marked as dirty.
    ///
    /// This is not very performant this is primarily used for assertions
    /// and testing.
    pub fn isDirty(self: Cell) bool {
        return self.node.page().dirty or self.row.dirty;
    }

    /// Get the cell style.
    ///
    /// Not meant for non-test usage since this is inefficient.
    pub fn style(self: Cell) stylepkg.Style {
        if (self.cell.style_id == stylepkg.default_id) return .{};
        const page = self.node.page();
        return page.styles.get(
            page.memory,
            self.cell.style_id,
        ).*;
    }

    /// Gets the screen point for the given cell.
    ///
    /// This is REALLY expensive/slow so it isn't pub. This was built
    /// for debugging and tests. If you have a need for this outside of
    /// this file then consider a different approach and ask yourself very
    /// carefully if you really need this.
    pub fn screenPoint(self: Cell) point.Point {
        var y: u32 = self.row_idx;
        var node_ = self.node;
        while (node_.prev) |node| {
            y += node.rows();
            node_ = node;
        }

        return .{ .screen = .{
            .x = self.col_idx,
            .y = y,
        } };
    }
};

/// Page construction for regression fixtures only; absent from application builds.
pub const TestSupport = if (builtin.is_test) @import("tests/PageList/fixtures.zig") else struct {};

/// White-box regression hooks; absent from application builds.
pub const TestAccess = if (builtin.is_test) struct {
    pub const pageAllocator = PageList.pageAllocator;
    pub const createPageExt = PageList.createPageExt;
    pub const destroyNodeExt = PageList.destroyNodeExt;
    pub const initTrackedPins = PageList.initTrackedPins;
    pub const compressionIterator = PageList.CompressionIterator.init;
    pub const nextCompressionPage = PageList.CompressionIterator.next;
    pub const compressionActivity = PageList.IncrementalCompressionState.markActivity;
    pub const resetCompression = PageList.IncrementalCompressionState.reset;
    pub const PageOwnership = PageList.Node.Owned;
    pub const createPage = PageList.createPage;
    pub const nodeIsCompressed = PageList.Node.isCompressed;
    pub const nodeMetadata = PageList.Node.metadata;
    pub const minMaxLines = PageList.Limits.minMaxLines;

    pub const page_preheat = PageList.page_preheat;
    pub const Node = PageList.Node;
    pub const std_capacity = PageList.std_capacity;
    pub const std_size = PageList.std_size;
    pub const PagePool = PageList.PagePool;
    pub const initialCapacity = PageList.initialCapacity;
    pub const init_tw = PageList.init_tw;
    pub const initPages_tw = PageList.initPages_tw;
    pub const resizeWithoutReflow = PageList.resizeWithoutReflow;
    pub const trimTrailingBlankRows = PageList.trimTrailingBlankRows;
    pub const IncrementalCompressionState = PageList.IncrementalCompressionState;
    pub const CompressionIterator = PageList.CompressionIterator;
    pub const incremental_compression_max_inspected = PageList.incremental_compression_max_inspected;
    pub const compressPage_tw = PageList.compressPage_tw;
    pub const compressPage = PageList.compressPage;
    pub const destroyNode = PageList.destroyNode;
    pub const totalRows = PageList.totalRows;
    pub const growRows = PageList.growRows;
    pub const markDirty = PageList.markDirty;
    pub const Limits = PageList.Limits;
} else struct {};

test {
    _ = @import("tests/PageList/pages.zig");
    _ = @import("tests/PageList/storage.zig");
    _ = @import("tests/PageList/pins.zig");
    _ = @import("tests/PageList/reflow.zig");
    _ = @import("tests/PageList/operations.zig");
}
