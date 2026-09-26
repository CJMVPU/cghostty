const Screen = @This();

const std = @import("std");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const ansi = @import("ansi.zig");
const charsets = @import("charsets.zig");
const fastmem = @import("../fastmem.zig");
const kitty = @import("kitty.zig");
const sgr = @import("sgr.zig");
const tripwire = @import("../tripwire.zig");
const unicode = @import("../unicode/main.zig");
const Selection = @import("Selection.zig");
const PageList = @import("PageList.zig");
const StringMap = @import("StringMap.zig");
const ScreenFormatter = @import("formatter.zig").ScreenFormatter;
const PinMap = @import("formatter.zig").PinMap;
const osc = @import("osc.zig");
const pagepkg = @import("page.zig");
const point = @import("point.zig");
const size = @import("size.zig");
const style = @import("style.zig");
const hyperlink = @import("hyperlink.zig");
const Offset = size.Offset;
const Page = pagepkg.Page;
const Row = pagepkg.Row;
const Cell = pagepkg.Cell;
const Pin = PageList.Pin;

pub const CursorStyle = @import("cursor.zig").Style;

const log = std.log.scoped(.screen);

/// The I/O implementation to use for any operation that requires one.
io: std.Io,

/// The general purpose allocator to use for all memory allocations.
/// Unfortunately some screen operations do require allocation.
alloc: Allocator,

/// The list of pages in the screen.
pages: PageList,

/// Special-case where we want no scrollback whatsoever. We have to flag
/// this because max_size 0 in PageList gets rounded up to two pages so
/// we can always have an active screen.
no_scrollback: bool = false,

/// The current cursor position
cursor: Cursor,

/// The saved cursor
saved_cursor: ?SavedCursor = null,

/// The selection for this screen (if any). This MUST be a tracked selection
/// otherwise the selection will become invalid. Instead of accessing this
/// directly to set it, use the `select` function which will assert and
/// automatically setup tracking.
selection: ?Selection = null,

/// The charset state
charset: CharsetState = .{},

/// The current or most recent protected mode. Once a protection mode is
/// set, this will never become "off" again until the screen is reset.
/// The current state of whether protection attributes should be set is
/// set on the Cell pen; this is only used to determine the most recent
/// protection mode since some sequences such as ECH depend on this.
protected_mode: ansi.ProtectedMode = .off,

/// The kitty keyboard settings.
kitty_keyboard: kitty.KeyFlagStack = .{},

/// Kitty graphics protocol state.
kitty_images: kitty.graphics.ImageStorage = .{},

/// Semantic prompt (OSC133) state.
semantic_prompt: SemanticPrompt = .disabled,

/// Conservative text mutation epoch; never cleared by the renderer.
accessibility_revision: u64 = 0,

/// Dirty flags for the renderer.
dirty: Dirty = .{},

/// See Terminal.Dirty. This behaves the same way.
pub const Dirty = packed struct {
    /// Set when the selection is set or unset, regardless of if the
    /// selection is changed or not.
    selection: bool = false,

    /// When an OSC8 hyperlink is hovered, we set the full screen as dirty
    /// because links can span multiple lines.
    hyperlink_hover: bool = false,
};

pub const SemanticPrompt = struct {
    /// This is flipped to true when any sort of semantic content is
    /// seen. In particular, this is set to true only when a `prompt` type
    /// is ever set on our cursor.
    ///
    /// This is used to optimize away semantic content operations if we know
    /// we've never seen them.
    seen: bool,

    /// This is set on any `cl` or `click_events` option set on the
    /// most recent OSC 133 commands to specify how click handling in a
    /// prompt is handling.
    click: SemanticClick,

    pub const disabled: SemanticPrompt = .{
        .seen = false,
        .click = .none,
    };

    pub const SemanticClickKind = enum(u2) {
        none = 0,
        click_events = 1,
        cl = 2,
    };

    pub const SemanticClick = union(SemanticClickKind) {
        none,
        click_events: osc.semantic_prompt.ClickEvents,
        cl: osc.semantic_prompt.Click,
    };
};

/// The cursor position and style.
pub const Cursor = struct {
    // The x/y position within the active area.
    x: size.CellCountInt = 0,
    y: size.CellCountInt = 0,

    /// The visual style of the cursor. This defaults to block because
    /// it has to default to something, but users of this struct are
    /// encouraged to set their own default.
    cursor_style: CursorStyle = .block,

    /// The "last column flag (LCF)" as its called. If this is set then the
    /// next character print will force a soft-wrap.
    pending_wrap: bool = false,

    /// The protected mode state of the cursor. If this is true then
    /// all new characters printed will have the protected state set.
    protected: bool = false,

    /// The currently active style. This is the concrete style value
    /// that should be kept up to date. The style ID to use for cell writing
    /// is below.
    style: style.Style = .{},

    /// The currently active style ID. The style is page-specific so when
    /// we change pages we need to ensure that we update that page with
    /// our style when used.
    style_id: style.Id = style.default_id,

    /// The hyperlink ID that is currently active for the cursor. A value
    /// of zero means no hyperlink is active. (Implements OSC8, saying that
    /// so code search can find it.).
    hyperlink_id: hyperlink.Id = 0,

    /// This is the implicit ID to use for hyperlinks that don't specify
    /// an ID. We do an overflowing add to this so repeats can technically
    /// happen with carefully crafted inputs but for real workloads its
    /// highly unlikely -- and the fix is for the TUI program to use explicit
    /// IDs.
    hyperlink_implicit_id: size.OffsetInt = 0,

    /// Heap-allocated hyperlink state so that we can recreate it when
    /// the cursor page pin changes. We can't get it from the old screen
    /// state because the page may be cleared. This is heap allocated
    /// because its most likely null.
    hyperlink: ?*hyperlink.Hyperlink = null,

    /// The current semantic content type for the cursor that will be
    /// applied to any newly written cells.
    semantic_content: pagepkg.Cell.SemanticContent = .output,
    semantic_content_clear_eol: bool = false,

    /// The pointers into the page list where the cursor is currently
    /// located. This makes it faster to move the cursor.
    page_pin: *PageList.Pin,
    page_row: *pagepkg.Row,
    page_cell: *pagepkg.Cell,

    pub fn deinit(self: *Cursor, alloc: Allocator) void {
        if (self.hyperlink) |link| {
            link.deinit(alloc);
            alloc.destroy(link);
        }
    }
};

/// Saved cursor state.
pub const SavedCursor = struct {
    x: size.CellCountInt,
    y: size.CellCountInt,
    style: style.Style,
    protected: bool,
    pending_wrap: bool,
    origin: bool,
    charset: CharsetState,
};

/// State required for all charset operations.
pub const CharsetState = struct {
    /// The list of graphical charsets by slot
    charsets: CharsetArray = .{},

    /// GL is the slot to use when using a 7-bit printable char (up to 127)
    /// GR used for 8-bit printable chars.
    gl: charsets.Slots = .G0,
    gr: charsets.Slots = .G2,

    /// Single shift where a slot is used for exactly one char.
    single_shift: ?charsets.Slots = null,

    /// An array to map a charset slot to a lookup table.
    ///
    /// We use this bespoke struct instead of `std.EnumArray` because
    /// accessing these slots is very performance critical since it's
    /// done for every single print. This benchmarks faster.
    const CharsetArray = struct {
        g0: charsets.Charset = .utf8,
        g1: charsets.Charset = .utf8,
        g2: charsets.Charset = .utf8,
        g3: charsets.Charset = .utf8,

        pub inline fn get(
            self: *const CharsetArray,
            slot: charsets.Slots,
        ) charsets.Charset {
            return switch (slot) {
                .G0 => self.g0,
                .G1 => self.g1,
                .G2 => self.g2,
                .G3 => self.g3,
            };
        }

        pub inline fn set(
            self: *CharsetArray,
            slot: charsets.Slots,
            charset: charsets.Charset,
        ) void {
            switch (slot) {
                .G0 => self.g0 = charset,
                .G1 => self.g1 = charset,
                .G2 => self.g2 = charset,
                .G3 => self.g3 = charset,
            }
        }
    };
};

pub const Options = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,

    /// The maximum size of scrollback in bytes. Null is unlimited, zero
    /// disables scrollback, and any other value is clamped to support a
    /// minimum of the active area.
    max_scrollback_bytes: ?usize = 0,

    /// The maximum number of physical scrollback rows, excluding the active
    /// area. Null is unlimited. The effective limit permits at least one
    /// standard page and only complete historical pages are pruned.
    max_scrollback_lines: ?usize = null,

    /// The total storage limit for Kitty images in bytes for this
    /// screen. Kitty image storage is per-screen.
    kitty_image_storage_limit: usize = 320 * 1000 * 1000,

    /// The limits for what medium types are allowed for Kitty image loading.
    kitty_image_loading_limits: kitty.graphics.LoadingImage.Limits = .direct,

    /// A simple, default terminal. If you rely on specific dimensions or
    /// scrollback (or lack of) then do not use this directly. This is just
    /// for callers that need some defaults.
    pub const default: Options = .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 0,
    };
};

/// Initialize a new screen.
///
/// max_scrollback_bytes is the amount of scrollback to keep in bytes. This
/// will be rounded UP to the nearest page size because our minimum allocation
/// size is that anyways.
///
/// If max scrollback is 0, then no scrollback is kept at all.
pub fn init(
    io: std.Io,
    alloc: Allocator,
    opts: Options,
) Allocator.Error!Screen {
    // Initialize our backing pages.
    var pages = try PageList.init(alloc, .{
        .cols = opts.cols,
        .rows = opts.rows,
        .max_size = opts.max_scrollback_bytes,
        .max_lines = opts.max_scrollback_lines,
    });
    errdefer pages.deinit();

    // Create our tracked pin for the cursor.
    const page_pin = try pages.trackPin(.{ .node = pages.pages.first.? });
    errdefer pages.untrackPin(page_pin);
    const page_rac = page_pin.rowAndCell();

    var result: Screen = .{
        .io = io,
        .alloc = alloc,
        .pages = pages,
        .no_scrollback = opts.max_scrollback_bytes == 0,
        .cursor = .{
            .x = 0,
            .y = 0,
            .page_pin = page_pin,
            .page_row = page_rac.row,
            .page_cell = page_rac.cell,
        },
    };

    {
        result.kitty_images.setLimit(
            io,
            alloc,
            &result,
            opts.kitty_image_storage_limit,
        );
        result.kitty_images.image_limits = opts.kitty_image_loading_limits;
    }

    return result;
}

pub fn deinit(self: *Screen) void {
    {
        self.kitty_images.deinit(self.alloc, self);
    }
    self.cursor.deinit(self.alloc);
    self.pages.deinit();
}

/// Assert that the screen is in a consistent state. This doesn't check
/// all pages in the page list because that is SO SLOW even just for
/// tests. This only asserts the screen specific data so callers should
/// ensure they're also calling page integrity checks if necessary.
pub fn assertIntegrity(self: *const Screen) void {
    if (build_options.slow_runtime_safety) {
        // We don't run integrity checks on Valgrind because its soooooo slow,
        // Valgrind is our integrity checker, and we run these during unit
        // tests (non-Valgrind) anyways so we're verifying anyways.
        if (std.valgrind.runningOnValgrind() > 0) return;

        assert(self.cursor.x < self.pages.cols);
        assert(self.cursor.y < self.pages.rows);

        // Our cursor x/y should always match the pin. If this doesn't
        // match then it indicates that the tracked pin moved and we didn't
        // account for it by either calling cursorReload or manually
        // adjusting.
        const pt: point.Point = self.pages.pointFromPin(
            .active,
            self.cursor.page_pin.*,
        ) orelse unreachable;
        assert(self.cursor.x == pt.active.x);
        assert(self.cursor.y == pt.active.y);

        // The cursor style and hyperlink if non-zero must reference
        // real data in the page the pin is in.
        const page: *const Page = self.cursor.page_pin.node.page();
        if (self.cursor.style_id != style.default_id) {
            assert(page.styles.refCount(page.memory, self.cursor.style_id) > 0);
        }
        if (self.cursor.hyperlink_id != 0) {
            assert(page.hyperlink_set.refCount(page.memory, self.cursor.hyperlink_id) > 0);
        }
    }
}

/// Reset the screen according to the logic of a DEC RIS sequence.
///
/// - Clears the screen and attempts to reclaim memory.
/// - Moves the cursor to the top-left.
/// - Clears any cursor state: style, hyperlink, etc.
/// - Resets the charset
/// - Clears the selection
/// - Deletes all Kitty graphics
/// - Resets Kitty Keyboard settings
/// - Disables protection mode
///
pub fn reset(self: *Screen) void {
    self.accessibility_revision +%= 1;
    // Reset our pages
    self.pages.reset();

    // The above reset preserves tracked pins so we can still use
    // our cursor pin, which should be at the top-left already. The
    // reset marks every tracked pin as garbage, but we keep using
    // this one at its new valid position, so clear the flag: copies
    // of the cursor pin (e.g. for Kitty image placements) must not
    // be born garbage.
    const cursor_pin: *PageList.Pin = self.cursor.page_pin;
    assert(cursor_pin.node == self.pages.pages.first.?);
    assert(cursor_pin.x == 0);
    assert(cursor_pin.y == 0);
    cursor_pin.garbage = false;
    const cursor_rac = cursor_pin.rowAndCell();
    self.cursor.deinit(self.alloc);
    self.cursor = .{
        .page_pin = cursor_pin,
        .page_row = cursor_rac.row,
        .page_cell = cursor_rac.cell,
    };

    {
        // Reset kitty graphics storage
        const image_limits = self.kitty_images.image_limits;
        const total_limit = self.kitty_images.total_limit;
        self.kitty_images.deinit(self.alloc, self);
        self.kitty_images = .{
            .dirty = true,
            .image_limits = image_limits,
            .total_limit = total_limit,
        };
    }

    // Reset our basic state
    self.saved_cursor = null;
    self.charset = .{};
    self.kitty_keyboard = .{};
    self.protected_mode = .off;
    self.semantic_prompt = .disabled;
    self.clearSelection();
}

/// Clone the screen.
///
/// This will copy:
///
///   - Screen dimensions
///   - Screen data (cell state, etc.) for the region
///
/// Anything not mentioned above is NOT copied. Some of this is for
/// very good reason:
///
///   - Kitty images have a LOT of data. This is not efficient to copy.
///     Use a lock and access the image data. The dirty bit is there for
///     a reason.
///   - Cursor location can be expensive to calculate with respect to the
///     specified region. It is faster to grab the cursor from the old
///     screen and then move it to the new screen.
///   - Current hyperlink cursor state has heap allocations. Since clone
///     is only for read-only operations, it is better to not have any
///     hyperlink state. Note that already-written hyperlinks are cloned.
///
/// If not mentioned above, then there isn't a specific reason right now
/// to not copy some data other than we probably didn't need it and it
/// isn't necessary for screen coherency.
///
/// Other notes:
///
///   - The viewport will always be set to the active area of the new
///     screen. This is the bottom "rows" rows.
///   - If the clone region is smaller than a viewport area, blanks will
///     be filled in at the bottom.
///
pub fn clone(
    self: *const Screen,
    io: std.Io,
    alloc: Allocator,
    top: point.Point,
    bot: ?point.Point,
) !Screen {
    // Create a tracked pin remapper for our selection and cursor. Note
    // that we may want to expose this generally in the future but at the
    // time of doing this we don't need to.
    var pin_remap = PageList.Clone.TrackedPinsRemap.init(alloc);
    defer pin_remap.deinit();

    var pages = try self.pages.clone(alloc, .{
        .top = top,
        .bot = bot,
        .tracked_pins = &pin_remap,
    });
    errdefer pages.deinit();

    // Find our cursor. If the cursor isn't in the cloned area, we move it
    // to the top-left arbitrarily because a screen must have SOME cursor.
    const cursor: Cursor = cursor: {
        if (pin_remap.get(self.cursor.page_pin)) |p| remap: {
            const page_rac = p.rowAndCell();
            const pt = pages.pointFromPin(.active, p.*) orelse break :remap;
            break :cursor .{
                .x = @intCast(pt.active.x),
                .y = @intCast(pt.active.y),
                .page_pin = p,
                .page_row = page_rac.row,
                .page_cell = page_rac.cell,
            };
        }

        const page_pin = try pages.trackPin(.{ .node = pages.pages.first.? });
        const page_rac = page_pin.rowAndCell();
        break :cursor .{
            .x = 0,
            .y = 0,
            .page_pin = page_pin,
            .page_row = page_rac.row,
            .page_cell = page_rac.cell,
        };
    };

    // Preserve our selection if we have one.
    const sel: ?Selection = if (self.selection) |sel| sel: {
        assert(sel.tracked());

        const ordered: struct {
            tl: *Pin,
            br: *Pin,
        } = switch (sel.order(self)) {
            .forward, .mirrored_forward => .{
                .tl = sel.bounds.tracked.start,
                .br = sel.bounds.tracked.end,
            },
            .reverse, .mirrored_reverse => .{
                .tl = sel.bounds.tracked.end,
                .br = sel.bounds.tracked.start,
            },
        };

        const start_pin = pin_remap.get(ordered.tl) orelse start: {
            // No start means it is outside the cloned area.

            // If we have no end pin then either
            // (1) our whole selection is outside the cloned area or
            // (2) our cloned area is within the selection
            if (pin_remap.get(ordered.br) == null) {
                // We check if the selection bottom right pin is above
                // the cloned area or if the top left pin is below the
                // cloned area, in either of these cases it means that
                // the selection is fully out of bounds, so we have no
                // selection in the cloned area and break out now.
                const clone_top = self.pages.pin(top) orelse break :sel null;
                const clone_top_y = self.pages.pointFromPin(
                    .screen,
                    clone_top,
                ).?.screen.y;
                if (self.pages.pointFromPin(
                    .screen,
                    ordered.br.*,
                ).?.screen.y < clone_top_y) break :sel null;
                if (self.pages.pointFromPin(
                    .screen,
                    ordered.tl.*,
                ).?.screen.y > clone_top_y) break :sel null;
            }

            // We move the top pin back in bounds to the top row.
            const node = pages.pages.first.?;
            break :start try pages.trackPin(.{
                .node = node,
                .x = if (sel.rectangle)
                    @min(ordered.tl.x, node.cols() - 1)
                else
                    0,
            });
        };

        // If we got to this point it means that the selection is not
        // fully out of bounds, so we move the bottom right pin back
        // in bounds if it isn't already.
        const end_pin = pin_remap.get(ordered.br) orelse end: {
            const node = pages.pages.last.?;
            break :end try pages.trackPin(.{
                .node = node,
                .x = if (sel.rectangle)
                    @min(ordered.br.x, node.cols() - 1)
                else
                    node.cols() - 1,
                .y = node.rows() - 1,
            });
        };

        break :sel .{
            .bounds = .{ .tracked = .{
                .start = start_pin,
                .end = end_pin,
            } },
            .rectangle = sel.rectangle,
        };
    } else null;

    const result: Screen = .{
        .io = io,
        .alloc = alloc,
        .pages = pages,
        .no_scrollback = self.no_scrollback,
        .cursor = cursor,
        .selection = sel,
        .dirty = self.dirty,
    };
    result.assertIntegrity();
    return result;
}

pub fn increaseCapacity(
    self: *Screen,
    node: *PageList.List.Node,
    adjustment: ?PageList.IncreaseCapacity,
) PageList.IncreaseCapacityError!*PageList.List.Node {
    self.accessibility_revision +%= 1;
    // If the page being modified isn't our cursor page then
    // this is a quick operation because we have no additional
    // accounting. We have to do this check here BEFORE calling
    // increaseCapacity because increaseCapacity will update all
    // our tracked pins (including our cursor).
    if (node != self.cursor.page_pin.node) return try self.pages.increaseCapacity(
        node,
        adjustment,
    );

    // We're modifying the cursor page. When we increase the
    // capacity below it will be short the ref count on our
    // current style and hyperlink, so we need to init those.
    const new_node = try self.pages.increaseCapacity(node, adjustment);
    const new_page: *Page = new_node.page();

    // Re-add the style, if the page somehow doesn't have enough
    // memory to add it, we emit a warning and gracefully degrade
    // to the default style for the cursor.
    if (self.cursor.style_id != style.default_id) {
        self.cursor.style_id = new_page.styles.add(
            new_page.memory,
            self.cursor.style,
        ) catch |err| id: {
            // TODO: Should we increase the capacity further in this case?
            log.warn(
                "(Screen.increaseCapacity) Failed to add cursor style back to page, err={}",
                .{err},
            );

            // Reset the cursor style.
            self.cursor.style = .{};
            break :id style.default_id;
        };
    }

    // Re-add the hyperlink, if the page somehow doesn't have enough
    // memory to add it, we emit a warning and gracefully degrade to
    // no hyperlink.
    if (self.cursor.hyperlink) |link| {
        // So we don't attempt to free any memory in the replaced page.
        self.cursor.hyperlink_id = 0;
        self.cursor.hyperlink = null;

        // Re-add
        self.startHyperlinkOnce(link.*) catch |err| {
            // TODO: Should we increase the capacity further in this case?
            log.warn(
                "(Screen.increaseCapacity) Failed to add cursor hyperlink back to page, err={}",
                .{err},
            );
        };

        // Remove our old link
        link.deinit(self.alloc);
        self.alloc.destroy(link);
    }

    // Reload the cursor information because the pin changed.
    // So our page row/cell and so on are all off.
    self.cursorReload();

    return new_node;
}

/// Clone the cells in columns [x_start, x_end) of a source row into
/// the row at `dst_y` of the given node's page, increasing the node's
/// capacity as necessary to fit the managed memory (styles,
/// hyperlinks, etc.) of the copied cells.
///
/// This is the Screen-level analog of PageList.cloneRowGrowCapacity:
/// capacity increases are routed through Screen.increaseCapacity so
/// that the cursor's style/hyperlink references are migrated when the
/// destination node is the cursor's page.
///
/// Since increasing capacity replaces the node in the page list, the
/// (possibly replaced) node is returned and the caller must use it in
/// place of the old node. Tracked pins are updated automatically. The
/// source must NOT be on the given node since the node's page memory
/// may be freed on capacity increase.
///
/// Callers use this mid-mutation (after rows have been rotated or
/// shifted), so a failure can't be propagated without leaving the
/// page list half-mutated (and corrupt). If the capacity can't be
/// increased (system OOM or the page is already at max capacity),
/// this panics: a crash is better than corruption.
pub fn clonePartialRowGrowCapacity(
    self: *Screen,
    node: *PageList.List.Node,
    dst_y: usize,
    src_page: *Page,
    src_row: *const Row,
    x_start: usize,
    x_end: usize,
) *PageList.List.Node {
    self.accessibility_revision +%= 1;
    assert(src_page != node.page());

    var current = node;
    while (true) {
        const cur_page: *Page = current.page();
        const cur_rows = cur_page.rows.ptr(cur_page.memory.ptr);
        cur_page.clonePartialRowFrom(
            src_page,
            &cur_rows[dst_y],
            src_row,
            x_start,
            x_end,
        ) catch |err| {
            // Adjust our page capacity to make room for what we
            // didn't have space for and retry the copy.
            current = self.increaseCapacity(
                current,
                PageList.IncreaseCapacity.forCloneError(err),
            ) catch |e| switch (e) {
                // We can't gracefully recover from either of these
                // here: our callers have already rotated or shifted
                // rows, so returning an error would leave the page
                // list half-mutated (and corrupt), so a crash is
                // better.
                error.OutOfMemory,
                => @panic("increaseCapacity system allocator OOM"),

                error.OutOfSpace,
                => @panic("increaseCapacity OutOfSpace"),
            };

            continue;
        };

        return current;
    }
}

pub inline fn cursorCellRight(self: *Screen, n: size.CellCountInt) *pagepkg.Cell {
    assert(self.cursor.x + n < self.pages.cols);
    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    return @ptrCast(cell + n);
}

pub inline fn cursorCellLeft(self: *Screen, n: size.CellCountInt) *pagepkg.Cell {
    assert(self.cursor.x >= n);
    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    return @ptrCast(cell - n);
}

pub fn cursorCellEndOfPrev(self: *Screen) *pagepkg.Cell {
    assert(self.cursor.y > 0);

    var page_pin = self.cursor.page_pin.up(1).?;
    page_pin.x = page_pin.node.cols() - 1;
    const page_rac = page_pin.rowAndCell();
    return page_rac.cell;
}

/// Move the cursor right. This is a specialized function that is very fast
/// if the caller can guarantee we have space to move right (no wrapping).
pub fn cursorRight(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.x + n < self.pages.cols);
    defer self.assertIntegrity();

    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    self.cursor.page_cell = @ptrCast(cell + n);
    self.cursor.page_pin.x += n;
    self.cursor.x += n;
}

/// Move the cursor left.
pub fn cursorLeft(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.x >= n);
    defer self.assertIntegrity();

    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    self.cursor.page_cell = @ptrCast(cell - n);
    self.cursor.page_pin.x -= n;
    self.cursor.x -= n;
}

/// Move the cursor up.
///
/// Precondition: The cursor is not at the top of the screen.
pub fn cursorUp(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.y >= n);
    defer self.assertIntegrity();

    self.cursor.y -= n; // Must be set before cursorChangePin
    self.cursorChangePin(self.cursor.page_pin.up(n).?);
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}

pub fn cursorRowUp(self: *Screen, n: size.CellCountInt) *pagepkg.Row {
    assert(self.cursor.y >= n);
    defer self.assertIntegrity();

    const page_pin = self.cursor.page_pin.up(n).?;
    const page_rac = page_pin.rowAndCell();
    return page_rac.row;
}

/// Move the cursor down.
///
/// Precondition: The cursor is not at the bottom of the screen.
pub fn cursorDown(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.y + n < self.pages.rows);
    defer self.assertIntegrity();

    self.cursor.y += n; // Must be set before cursorChangePin

    // We move the offset into our page list to the next row and then
    // get the pointers to the row/cell and set all the cursor state up.
    self.cursorChangePin(self.cursor.page_pin.down(n).?);
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}

/// Move the cursor to some absolute horizontal position.
pub fn cursorHorizontalAbsolute(self: *Screen, x: size.CellCountInt) void {
    assert(x < self.pages.cols);
    defer self.assertIntegrity();

    self.cursor.page_pin.x = x;
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_cell = page_rac.cell;
    self.cursor.x = x;
}

/// Move the cursor to some absolute position.
pub fn cursorAbsolute(self: *Screen, x: size.CellCountInt, y: size.CellCountInt) void {
    assert(x < self.pages.cols);
    assert(y < self.pages.rows);
    defer self.assertIntegrity();

    var page_pin = if (y < self.cursor.y)
        self.cursor.page_pin.up(self.cursor.y - y).?
    else if (y > self.cursor.y)
        self.cursor.page_pin.down(y - self.cursor.y).?
    else
        self.cursor.page_pin.*;
    page_pin.x = x;
    self.cursor.x = x; // Must be set before cursorChangePin
    self.cursor.y = y;
    self.cursorChangePin(page_pin);
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}

/// Reloads the cursor pointer information into the screen. This is expensive
/// so it should only be done in cases where the pointers are invalidated
/// in such a way that its difficult to recover otherwise.
pub fn cursorReload(self: *Screen) void {
    defer self.assertIntegrity();

    // Our tracked pin is ALWAYS accurate, so we derive the active
    // point from the pin. If this returns null it means our pin
    // points outside the active area. In that case, we update the
    // pin to be the top-left.
    const pt: point.Point = self.pages.pointFromPin(
        .active,
        self.cursor.page_pin.*,
    ) orelse reset: {
        // Our cached row/cell pointers may be invalid (that is often
        // the reason cursorReload is being called), so refresh them
        // from the pin first since cursorChangePin below marks the
        // old cursor row as dirty.
        const old_rac = self.cursor.page_pin.rowAndCell();
        self.cursor.page_row = old_rac.row;
        self.cursor.page_cell = old_rac.cell;

        // The cursor style and hyperlink IDs are only valid within the
        // page that the pin points at, so the pin change must go through
        // cursorChangePin, which migrates them when the active top-left
        // is on a different page. Writing the pin directly here would
        // leave the cursor holding IDs that are dead or alias unrelated
        // entries on the new page.
        const pin = self.pages.pin(.{ .active = .{} }).?;
        self.cursor.x = 0; // Must be set before cursorChangePin
        self.cursor.y = 0;
        self.cursorChangePin(pin);

        // cursorChangePin can trigger a page capacity adjustment which
        // moves the pin again, so we re-read it to derive our point.
        break :reset self.pages.pointFromPin(
            .active,
            self.cursor.page_pin.*,
        ).?;
    };

    self.cursor.x = @intCast(pt.active.x);
    self.cursor.y = @intCast(pt.active.y);
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}

/// Scroll the active area and keep the cursor at the bottom of the screen.
/// This is a very specialized function but it keeps it fast.
pub fn cursorDownScroll(self: *Screen) !void {
    self.accessibility_revision +%= 1;
    assert(self.cursor.y == self.pages.rows - 1);
    defer self.assertIntegrity();

    {
        // Scrolling dirties the images because it updates their placements pins.
        self.kitty_images.dirty = true;
    }

    // If we have no scrollback, then we shift all our rows instead.
    if (self.no_scrollback) {
        // If we have a single-row screen, we have no rows to shift
        // so our cursor is in the correct place we just have to clear
        // the cells.
        if (self.pages.rows == 1) {
            const page: *Page = self.cursor.page_pin.node.page();
            self.clearCells(
                page,
                self.cursor.page_row,
                page.getCells(self.cursor.page_row),
            );

            // The row is a fresh blank row now and must not retain
            // metadata (wrap state, semantic prompt) from the
            // discarded content.
            self.cursor.page_row.reset();

            self.cursorMarkDirty();
        } else {
            // The call to `eraseRow` will move the tracked cursor pin up by one
            // row, but we don't actually want that, so we keep the old pin and
            // put it back after calling `eraseRow`.
            const old_pin = self.cursor.page_pin.*;

            // eraseRow will shift everything below it up.
            try self.pages.eraseRow(.{ .active = .{} });

            // Note we don't need to mark anything dirty in this branch
            // because eraseRow will mark all the rotated rows as dirty
            // in the entire page.

            // We don't use `cursorChangePin` here because we aren't
            // actually changing the pin, we're keeping it the same.
            self.cursor.page_pin.* = old_pin;

            // We do, however, need to refresh the cached page row
            // and cell, because `eraseRow` will have moved the row.
            const page_rac = self.cursor.page_pin.rowAndCell();
            self.cursor.page_row = page_rac.row;
            self.cursor.page_cell = page_rac.cell;
        }
    } else {
        const old_pin = self.cursor.page_pin.*;

        // Grow our pages by one row. The PageList will handle if we need to
        // allocate, prune scrollback, whatever.
        _ = try self.pages.grow();

        const new_pin = new_pin: {
            // Calculate this before cursorChangePin because that function may
            // adjust the underlying page and invalidate references to its pin.

            // If our pin page change it means that the page that the pin
            // was on was pruned. In this case, grow() moves the pin to
            // the top-left of the new page. This effectively moves it by
            // one already, we just need to fix up the x value.
            const page_pin = if (old_pin.node == self.cursor.page_pin.node)
                self.cursor.page_pin.down(1).?
            else reuse: {
                var pin = self.cursor.page_pin.*;
                pin.x = self.cursor.x;
                break :reuse pin;
            };

            // These assertions help catch some pagelist math errors. Our
            // x/y should be unchanged after the grow.
            if (build_options.slow_runtime_safety) {
                const active = self.pages.pointFromPin(
                    .active,
                    page_pin,
                ).?.active;
                assert(active.x == self.cursor.x);
                assert(active.y == self.cursor.y);
            }

            break :new_pin page_pin;
        };

        if (self.cursor.page_pin.node == new_pin.node) {
            // Scrolling normally stays within one page. Resolve the page once
            // while refreshing the cursor pointers. The cursor already holds
            // live row and cell pointers into this mapping, and grow does not
            // compress pages, so the node must still be resident here.
            self.cursorMarkDirty();
            const page = new_pin.node.pageAssumeResident();
            const page_rac = page.getRowAndCell(new_pin.x, new_pin.y);
            self.cursor.page_pin.* = new_pin;
            self.cursor.page_row = page_rac.row;
            self.cursor.page_cell = page_rac.cell;
        } else {
            // Crossing a page may require migrating the cursor's style and
            // hyperlink references, so retain the general path here.
            self.cursorChangePin(new_pin);
            const page_rac = self.cursor.page_pin.rowAndCell();
            self.cursor.page_row = page_rac.row;
            self.cursor.page_cell = page_rac.cell;
        }

        // Our new row is always dirty
        self.cursorMarkDirty();

        // Clear the new row so it gets our bg color. We only do this
        // if we have a bg color at all.
        if (self.cursor.style.bg_color != .none) {
            const page: *Page = self.cursor.page_pin.node.page();
            self.clearCells(
                page,
                self.cursor.page_row,
                page.getCells(self.cursor.page_row),
            );
        }
    }

    if (self.cursor.style_id != style.default_id) {
        // The newly created line needs to be styled according to
        // the bg color if it is set.
        if (self.cursor.style.bgCell()) |blank_cell| {
            const cell_current: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
            const cells = cell_current - self.cursor.x;
            @memset(cells[0..self.pages.cols], blank_cell);
        }
    }
}

/// This scrolls the active area at and above the cursor.
/// The lines below the cursor are not scrolled.
pub fn cursorScrollAbove(self: *Screen) !void {
    self.accessibility_revision +%= 1;
    // We unconditionally mark the cursor row as dirty here because
    // the cursor always changes page rows inside this function, and
    // when that happens it can mean the text in the old row needs to
    // be re-shaped because the cursor splits runs to break ligatures.
    self.cursorMarkDirty();

    // If the cursor is on the bottom of the screen, its faster to use
    // our specialized function for that case.
    if (self.cursor.y == self.pages.rows - 1) {
        return try self.cursorDownScroll();
    }

    defer self.assertIntegrity();

    // Logic below assumes we always have at least one row that isn't moving
    assert(self.cursor.y < self.pages.rows - 1);

    // Explanation:
    //  We don't actually move everything that's at or above the cursor row,
    //  since this would require us to shift up our ENTIRE scrollback, which
    //  would be ridiculously expensive. Instead, we insert a new row at the
    //  end of the pagelist (`grow()`), and move everything BELOW the cursor
    //  DOWN by one row. This has the same practical result but it's a whole
    //  lot cheaper in 99% of cases.

    const old_pin = self.cursor.page_pin.*;
    if (try self.pages.grow()) |new_node| {
        try self.cursorScrollAboveRotate(new_node);
    } else {
        // In this case, it means grow() didn't allocate a new page.

        if (self.cursor.page_pin.node == self.pages.pages.last) {
            // If we're on the last page we can do a very fast path because
            // all the rows we need to move around are within a single page.

            // Note: we don't need to call cursorChangePin here because
            // the pin page is the same so there is no accounting to do
            // for styles or any of that.
            assert(old_pin.node == self.cursor.page_pin.node);
            self.cursor.page_pin.* = self.cursor.page_pin.down(1).?;

            const pin = self.cursor.page_pin;
            const page: *Page = self.cursor.page_pin.node.page();

            // Rotate the rows so that the newly created empty row is at the
            // beginning. e.g. [ 0 1 2 3 ] in to [ 3 0 1 2 ].
            var rows = page.rows.ptr(page.memory.ptr);
            // Rotating this suffix changes which logical row its coordinates identify.
            self.pages.invalidateNodeLayout(pin.node);
            fastmem.rotateOnceR(Row, rows[pin.y..page.size.rows]);

            // Mark the whole page as dirty.
            //
            // Technically we only need to mark from the cursor row to the
            // end but this is a hot function, so we want to minimize work.
            page.dirty = true;

            // Setup our cursor caches after the rotation so it points to the
            // correct data
            const page_rac = self.cursor.page_pin.rowAndCell();
            self.cursor.page_row = page_rac.row;
            self.cursor.page_cell = page_rac.cell;
        } else {
            // We didn't grow pages but our cursor isn't on the last page.
            // In this case we need to do more work because we need to copy
            // elements between pages.
            //
            // An example scenario of this is shown below:
            //
            //      +----------+ = PAGE 0
            //  ... :          :
            //     +-------------+ ACTIVE
            // 4302 |1A00000000| | 0
            // 4303 |2B00000000| | 1
            //      :^         : : = PIN 0
            // 4304 |3C00000000| | 2
            //      +----------+ :
            //      +----------+ : = PAGE 1
            //    0 |4D00000000| | 3
            //    1 |5E00000000| | 4
            //      +----------+ :
            //     +-------------+
            try self.cursorScrollAboveRotate(null);
        }
    }

    if (self.cursor.style_id != style.default_id) {
        // The newly created line needs to be styled according to
        // the bg color if it is set.
        if (self.cursor.style.bgCell()) |blank_cell| {
            const cell_current: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
            const cells = cell_current - self.cursor.x;
            @memset(cells[0..self.pages.cols], blank_cell);
        }
    }
}

fn cursorScrollAboveRotate(
    self: *Screen,
    fresh_node: ?*PageList.List.Node,
) !void {
    // A fresh node given to us is always the newly allocated tail of
    // the page list (see grow), which is where our iteration starts.
    assert(fresh_node == null or fresh_node == self.pages.pages.last);

    self.cursorChangePin(self.cursor.page_pin.down(1).?);

    // Go through each of the pages following our pin, shift all rows
    // down by one, and copy the last row of the previous page. We start
    // at the tail, which is the only node that can be freshly allocated.
    var current = self.pages.pages.last.?;
    var current_is_fresh = fresh_node != null;
    while (current != self.cursor.page_pin.node) : ({
        current = current.prev.?;
        current_is_fresh = false;
    }) {
        const prev = current.prev.?;

        // A newly allocated tail has no earlier references to invalidate.
        if (!current_is_fresh) {
            // Rotating this page moves every cached row coordinate down by one.
            self.pages.invalidateNodeLayout(current);
        }

        // Rotate the pages down: [ 0 1 2 3 ] => [ 3 0 1 2 ]
        {
            const cur_page = current.page();
            const cur_rows = cur_page.rows.ptr(cur_page.memory.ptr);
            fastmem.rotateOnceR(Row, cur_rows[0..cur_page.size.rows]);
        }

        // Copy the last row of the previous page to the top of current.
        // If the current page doesn't have enough capacity for the
        // managed memory of the copied row (styles, hyperlinks, etc.)
        // then its capacity is increased and the copy retried, which
        // may replace `current` in the page list. Our loop condition
        // guarantees `current` is never the cursor page, and `prev` is
        // unaffected by the replacement.
        {
            const prev_page = prev.page();
            const prev_rows = prev_page.rows.ptr(prev_page.memory.ptr);
            current = self.clonePartialRowGrowCapacity(
                current,
                0,
                prev_page,
                &prev_rows[prev_page.size.rows - 1],
                0,
                self.pages.cols,
            );
        }

        // Mark dirty on the page, since we are dirtying all rows with this.
        current.page().dirty = true;
    }

    // Our current is our cursor page, we need to rotate down from
    // our cursor and clear our row.
    assert(current == self.cursor.page_pin.node);
    const cur_page = current.page();
    const cur_rows = cur_page.rows.ptr(cur_page.memory.ptr);
    // Rotating the cursor-page suffix changes its cached row coordinates.
    self.pages.invalidateNodeLayout(current);
    fastmem.rotateOnceR(Row, cur_rows[self.cursor.page_pin.y..cur_page.size.rows]);
    self.clearCells(
        cur_page,
        &cur_rows[self.cursor.page_pin.y],
        cur_page.getCells(&cur_rows[self.cursor.page_pin.y]),
    );

    // The recycled storage becomes the new blank cursor row and must
    // not retain metadata (wrap state, semantic prompt) from the row
    // whose content was moved to the next page.
    cur_rows[self.cursor.page_pin.y].reset();

    // Mark the whole page as dirty.
    //
    // Technically we only need to mark from the cursor row to the
    // end but this is a hot function, so we want to minimize work.
    cur_page.dirty = true;

    // Setup cursor cache data after all the rotations so our
    // row is valid.
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}

/// Scroll a full-width scroll region that ends at the cursor row up by
/// one row. The cursor must be on the bottom row of the region. `limit`
/// is the number of rows in the region above the cursor (region height
/// minus one) and must be at least 1.
///
/// The top row of the region is discarded (NOT moved into scrollback).
/// All other rows in the region shift up by one and the cursor row
/// becomes a blank row, filled with the current background color (like
/// other scroll operations such as deleteLines).
///
/// The cursor stays at the same screen position (the new blank row).
/// Content outside of the region is unmodified.
///
/// This is a very hot path for scroll region usage (e.g. a program
/// on the alt screen using DECSTBM and scrolling via LF/IND) so this
/// is optimized for the common case where the full region is within
/// a single page.
pub fn cursorScrollRegionUp(self: *Screen, limit: usize) !void {
    self.accessibility_revision +%= 1;
    assert(limit >= 1);
    assert(self.cursor.y >= limit);
    defer self.assertIntegrity();

    const pin: *Pin = self.cursor.page_pin;

    // If the region crosses a page boundary we take a slower path. This
    // is rare: it requires the active area to span multiple pages with
    // the split point inside the scroll region.
    if (pin.y < limit) return try self.cursorScrollRegionUpSlow(limit);

    // Fast path: the entire region is in a single page. We can clear
    // the top row and rotate it down to the cursor row, updating any
    // tracked pins along the way.
    //
    // The cursor's cached row and cell pointers refer into this mapping.
    // PageList cannot compress the cursor page while those pointers are
    // installed, so the node is known to be resident here.
    const page: *Page = pin.node.pageAssumeResident();
    const rows = page.rows.ptr(page.memory.ptr)[pin.y - limit ..][0 .. limit + 1];

    // Clear the erased (top) row.
    {
        const row: *Row = &rows[0];

        // Whether our blank cell is a plain zero cell. This is true
        // unless the cursor has a background color set (see blankCell).
        const blank_is_zero = self.cursor.style_id == style.default_id or
            self.cursor.style.bg_color == .none;

        if (!row.managedMemory() and blank_is_zero) {
            // Hot path: the row has no managed memory (styles,
            // graphemes, hyperlinks) and our blank is zero so this is
            // a straight zero fill. This is the overwhelmingly common
            // case for scroll region usage.
            const cells = page.getCells(row);
            @memset(@as([]u64, @ptrCast(cells)), 0);
        } else {
            // The generic clear handles managed memory and fills the
            // row with our blank cell, preserving the background color.
            self.clearCells(page, row, page.getCells(row));
        }

        // The row becomes the new blank cursor row after the rotation
        // below and must not retain metadata (wrap state, semantic
        // prompt) from the discarded content.
        row.reset();
    }

    // Rotate the region rows so the now-blank top row moves to the
    // bottom (the cursor row) and everything else shifts up by one.
    // Rotating the region changes which logical row its coordinates identify.
    self.pages.invalidateNodeLayout(pin.node);
    fastmem.rotateOnce(Row, rows);

    // Mark the whole page as dirty.
    //
    // Technically we only need to mark the rotated rows but this is
    // a hot function, so we want to minimize work.
    page.dirty = true;

    // If our viewport is a pin and it's within the rotated region
    // then we need to shift its cached row offset up. See
    // PageList.eraseRowBounded for details; this mirrors that logic.
    if (self.pages.viewport == .pin) viewport: {
        if (self.pages.viewport_pin_row_offset) |*v| {
            const p = self.pages.viewport_pin;
            if (p.node != pin.node or
                p.y < pin.y - limit or
                p.y > pin.y or
                p.y == 0) break :viewport;
            v.* -= 1;
        }
    }

    // Update tracked pins within the region since their rows moved up
    // by one. The cursor's own pin is skipped because the cursor stays
    // at the region bottom (the new blank row).
    const pin_keys = self.pages.tracked_pins.keys();
    for (pin_keys) |p| {
        if (p.node != pin.node or
            p == pin or
            p.y < pin.y - limit or
            p.y > pin.y) continue;
        if (p.y == 0) p.x = 0 else p.y -= 1;
    }

    // The cursor pin is unchanged, but the Row structure at the pin
    // position now contains the blank row, so we need to refresh our
    // cached row/cell pointers. We compute them directly from the row
    // slice we already have rather than going through the pin since
    // this is a hot path.
    const cursor_row: *Row = &rows[limit];
    self.cursor.page_row = cursor_row;
    self.cursor.page_cell = &page.getCells(cursor_row)[self.cursor.x];
}

/// Slow path for cursorScrollRegionUp: the scroll region spans
/// multiple pages so we use the generic PageList erase machinery.
fn cursorScrollRegionUpSlow(self: *Screen, limit: usize) !void {
    // The call to eraseRowBounded below will move our tracked cursor
    // pin up by one row since it is inside the erased region, but we
    // don't actually want that: the cursor stays put, on the new blank
    // row at the region bottom. We keep the old pin and put it back
    // after, exactly like cursorDownScroll does for the no-scrollback
    // case.
    //
    // This matters beyond performance: when the cursor is on the first
    // row of a page, eraseRowBounded moves the tracked pin to the
    // previous page. Moving the cursor back down with cursorDown would
    // then cross pages via cursorChangePin, which migrates the cursor
    // style refcount from a page that never held it, corrupting the
    // style accounting.
    const old_pin = self.cursor.page_pin.*;

    try self.pages.eraseRowBounded(
        .{ .active = .{ .y = @intCast(self.cursor.y - limit) } },
        limit,
    );

    // We don't use `cursorChangePin` here because we aren't actually
    // changing the pin, we're keeping it the same. Since the page
    // never changes, the cursor's style ref stays valid and no style
    // accounting needs to be updated.
    self.cursor.page_pin.* = old_pin;

    // We do, however, need to refresh the cached page row and cell,
    // because the row contents at our pin position changed (it now
    // contains the blank row).
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;

    // eraseRowBounded clears the new row with zero cells so if our
    // blank cell isn't zero (bg color is set) we need to fill it.
    const blank = self.blankCell();
    if (!blank.isZero()) {
        const cells: [*]Cell = @ptrCast(self.cursor.page_cell);
        @memset((cells - self.cursor.x)[0..self.pages.cols], blank);
    }
}

/// Move the cursor down if we're not at the bottom of the screen. Otherwise
/// scroll. Currently only used for testing.
inline fn cursorDownOrScroll(self: *Screen) !void {
    if (self.cursor.y + 1 < self.pages.rows) {
        self.cursorDown(1);
    } else {
        try self.cursorDownScroll();
    }
}

/// Copy another cursor. The cursor can be on any screen but the x/y
/// must be within our screen bounds.
pub fn cursorCopy(self: *Screen, other: Cursor, opts: struct {
    /// Copy the hyperlink from the other cursor. If not set, this will
    /// clear our current hyperlink.
    hyperlink: bool = true,
}) !void {
    self.accessibility_revision +%= 1;
    assert(other.x < self.pages.cols);
    assert(other.y < self.pages.rows);

    // End any currently active hyperlink on our cursor.
    self.endHyperlink();

    const old = self.cursor;
    self.cursor = other;
    errdefer self.cursor = old;

    // Keep our old style ID so it can be properly cleaned up below.
    self.cursor.style_id = old.style_id;

    // Hyperlinks will be managed separately below.
    self.cursor.hyperlink_id = 0;
    self.cursor.hyperlink = null;

    // Keep our old page pin and X/Y because:
    // 1. The old style will need to be cleaned up from the page it's from.
    // 2. The new position navigated to by `cursorAbsolute` needs to be in our
    //    own screen.
    self.cursor.page_pin = old.page_pin;
    self.cursor.x = old.x;
    self.cursor.y = old.y;

    // Call manual style update in order to clean up our old style, if we have
    // one, and also to load the style from the other cursor, if it had one.
    try self.manualStyleUpdate();

    // Move to the correct location to match the other cursor.
    self.cursorAbsolute(other.x, other.y);

    // If the other cursor had a hyperlink, add it to ours.
    if (opts.hyperlink and other.hyperlink_id != 0) {
        // Get the hyperlink from the other cursor's page.
        const other_page = other.page_pin.node.page();
        const other_link = other_page.hyperlink_set.get(other_page.memory, other.hyperlink_id);

        const uri = other_link.uri.slice(other_page.memory);
        const id_ = switch (other_link.id) {
            .explicit => |id| id.slice(other_page.memory),
            .implicit => null,
        };

        // And it to our cursor.
        self.startHyperlink(uri, id_) catch |err| {
            // This shouldn't happen because startHyperlink should handle
            // resizing. This only happens if we're truly out of RAM. Degrade
            // to forgetting the hyperlink.
            log.err("failed to update hyperlink on cursor change err={}", .{err});
        };
    }
}

/// Always use this to write to cursor.page_pin.*.
///
/// This specifically handles the case when the new pin is on a different
/// page than the old AND we have a style or hyperlink set. In that case,
/// we must release our old one and insert the new one, since styles are
/// stored per-page.
///
/// Note that this can change the cursor pin AGAIN if the process of
/// setting up our cursor forces a capacity adjustment of the underlying
/// cursor page, so any references to the page pin should be re-read
/// from `self.cursor.page_pin` after calling this.
inline fn cursorChangePin(self: *Screen, new: Pin) void {
    // Moving the cursor affects text run splitting (ligatures) so
    // we must mark the old and new page dirty. We do this as long
    // as the pins are not equal
    if (!self.cursor.page_pin.eql(new)) {
        self.cursorMarkDirty();
        new.markDirty();
    }

    // If our pin is on the same page, then we can just update the pin.
    // We don't need to migrate any state.
    if (self.cursor.page_pin.node == new.node) {
        self.cursor.page_pin.* = new;
        return;
    }

    // If we have an old style then we need to release it from the old page.
    const old_style_: ?style.Style = if (self.cursor.style_id == style.default_id)
        null
    else
        self.cursor.style;
    if (old_style_ != null) {
        // Release the style directly from the old page instead of going through
        // manualStyleUpdate, because the cursor position may have already been
        // updated but the pin has not, which would fail integrity checks.
        const old_page: *Page = self.cursor.page_pin.node.page();
        old_page.styles.release(old_page.memory, self.cursor.style_id);
        self.cursor.style = .{};
        self.cursor.style_id = style.default_id;
    }

    // If we have a hyperlink then we need to release it from the old page.
    if (self.cursor.hyperlink != null) {
        const old_page: *Page = self.cursor.page_pin.node.page();
        old_page.hyperlink_set.release(old_page.memory, self.cursor.hyperlink_id);
        // Zero the ID, it is invalid now and style changes below may
        // run integrity checks. We still have self.cursor.hyperlink to
        // rebuild this later.
        self.cursor.hyperlink_id = 0;
    }

    // Update our pin to the new page
    self.cursor.page_pin.* = new;

    // On the new page, we need to migrate our style
    if (old_style_) |old_style| {
        self.cursor.style = old_style;
        self.manualStyleUpdate() catch |err| {
            // This failure should not happen because manualStyleUpdate
            // handles page splitting, overflow, and more. This should only
            // happen if we're out of RAM. In this case, we'll just degrade
            // gracefully back to the default style.
            log.err("failed to update style on cursor change err={}", .{err});
            self.cursor.style = .{};
            self.cursor.style_id = 0;
        };
    }

    // On the new page, we need to migrate our hyperlink
    if (self.cursor.hyperlink) |link| {
        // startHyperlink will try to free old hyperlinks, so set this
        // to null. We free it ourselves later since we're doing some
        // ref-counting shenanigans in this function.
        self.cursor.hyperlink = null;

        // Re-add
        self.startHyperlink(link.uri, switch (link.id) {
            .explicit => |v| v,
            .implicit => null,
        }) catch |err| {
            // This shouldn't happen because startHyperlink should handle
            // resizing. This only happens if we're truly out of RAM. Degrade
            // to forgetting the hyperlink.
            log.err("failed to update hyperlink on cursor change err={}", .{err});
        };

        // Remove our old link
        link.deinit(self.alloc);
        self.alloc.destroy(link);
    }
}

/// Mark the cursor position as dirty.
/// TODO: test
pub inline fn cursorMarkDirty(self: *Screen) void {
    self.cursor.page_row.dirty = true;
}

/// Reset the cursor row's soft-wrap state and the cursor's pending wrap.
/// Also handles clearing the spacer head on the cursor row and resetting
/// the wrap_continuation flag on the next row if necessary.
///
/// NOTE(qwerasd): This method is not scrolling region aware, and cannot be
/// since it's on Screen not Terminal. This needs to be addressed down the
/// line. Not an extremely urgent issue since it's an edge case of an edge
/// case, but not ideal.
pub fn cursorResetWrap(self: *Screen) void {
    self.accessibility_revision +%= 1;
    // Reset the cursor's pending wrap state
    self.cursor.pending_wrap = false;

    const page_row = self.cursor.page_row;

    if (!page_row.wrap) return;

    // This row does not wrap and the next row is not wrapped to
    page_row.wrap = false;

    if (self.cursor.page_pin.down(1)) |next_row| {
        next_row.rowAndCell().row.wrap_continuation = false;
    }

    // If the last cell in the row is a spacer head we need to clear it.
    const cells = self.cursor.page_pin.cells(.all);
    const cell = cells[self.cursor.page_pin.node.cols() - 1];
    if (cell.wide == .spacer_head) {
        self.clearCells(
            self.cursor.page_pin.node.page(),
            page_row,
            cells[self.cursor.page_pin.node.cols() - 1 ..][0..1],
        );
    }
}

/// Options for scrolling the viewport of the terminal grid. The reason
/// we have this in addition to PageList.Scroll is because we have additional
/// scroll behaviors that are not part of the PageList.Scroll enum.
pub const Scroll = union(enum) {
    /// For all of these, see PageList.Scroll.
    active,
    top,
    pin: Pin,
    row: usize,
    delta_row: isize,
    delta_prompt: isize,
};

/// Scroll the viewport of the terminal grid.
pub inline fn scroll(self: *Screen, behavior: Scroll) void {
    defer self.assertIntegrity();

    {
        // No matter what, scrolling marks our image state as dirty since
        // it could move placements. If there are no placements or no images
        // this is still a very cheap operation.
        self.kitty_images.dirty = true;
    }

    switch (behavior) {
        .active => self.pages.scroll(.{ .active = {} }),
        .top => self.pages.scroll(.{ .top = {} }),
        .pin => |p| self.pages.scroll(.{ .pin = p }),
        .row => |v| self.pages.scroll(.{ .row = v }),
        .delta_row => |v| self.pages.scroll(.{ .delta_row = v }),
        .delta_prompt => |v| self.pages.scroll(.{ .delta_prompt = v }),
    }
}

/// See PageList.scrollClear. In addition to that, we reset the cursor
/// to be on top.
pub inline fn scrollClear(self: *Screen) !void {
    self.accessibility_revision +%= 1;
    defer self.assertIntegrity();

    try self.pages.scrollClear();
    self.cursorReload();

    {
        // No matter what, scrolling marks our image state as dirty since
        // it could move placements. If there are no placements or no images
        // this is still a very cheap operation.
        self.kitty_images.dirty = true;
    }
}

/// Returns true if the viewport is scrolled to the bottom of the screen.
pub inline fn viewportIsBottom(self: Screen) bool {
    return self.pages.viewport == .active;
}

/// Erase the region specified by tl and br, inclusive. This will physically
/// erase the rows meaning the memory will be reclaimed (if the underlying
/// page is empty) and other rows will be shifted up.
pub inline fn eraseHistory(
    self: *Screen,
    bl: ?point.Point,
) void {
    self.accessibility_revision +%= 1;
    defer self.assertIntegrity();
    self.pages.eraseHistory(bl);
    self.cursorReload();
}

pub inline fn eraseActive(
    self: *Screen,
    y: size.CellCountInt,
) void {
    self.accessibility_revision +%= 1;
    defer self.assertIntegrity();
    self.pages.eraseActive(y);
    self.cursorReload();
}

// Clear the region specified by tl and bl, inclusive. Cleared cells are
// colored with the current style background color. This will clear all
// cells in the rows.
//
// If protected is true, the protected flag will be respected and only
// unprotected cells will be cleared. Otherwise, all cells will be cleared.
pub fn clearRows(
    self: *Screen,
    tl: point.Point,
    bl: ?point.Point,
    protected: bool,
) void {
    self.accessibility_revision +%= 1;
    defer self.assertIntegrity();

    var it = self.pages.pageIterator(.right_down, tl, bl);
    while (it.next()) |chunk| {
        const page = chunk.node.page();
        for (chunk.rows()) |*row| {
            const cells_offset = row.cells;
            const cells = page.getCells(row);

            // Clear all cells
            if (protected) {
                self.clearUnprotectedCells(page, row, cells);
                // We need to preserve other row attributes since we only
                // cleared unprotected cells.
                row.cells = cells_offset;
            } else {
                self.clearCells(page, row, cells);
                row.* = .{ .cells = cells_offset };
            }

            row.dirty = true;
        }
    }
}

/// Clear the cells with the blank cell.
///
/// This takes care to handle cleaning up graphemes and styles.
pub fn clearCells(
    self: *Screen,
    page: *Page,
    row: *Row,
    cells: []Cell,
) void {
    self.accessibility_revision +%= 1;
    if (cells.len == 0) return;

    // This whole operation does unsafe things, so we just want to assert
    // the end state.
    page.pauseIntegrityChecks(true);
    defer {
        page.pauseIntegrityChecks(false);
        page.assertIntegrity();
        self.assertIntegrity();
    }

    if (comptime std.debug.runtime_safety) {
        // Our row and cells should be within the page.
        const page_rows = page.rows.ptr(page.memory.ptr);
        assert(@intFromPtr(row) >= @intFromPtr(&page_rows[0]));
        assert(@intFromPtr(row) <= @intFromPtr(&page_rows[page.size.rows - 1]));

        const row_cells = page.getCells(row);
        assert(@intFromPtr(&cells[0]) >= @intFromPtr(&row_cells[0]));
        assert(@intFromPtr(&cells[cells.len - 1]) <= @intFromPtr(&row_cells[row_cells.len - 1]));
    }

    // If we have managed memory (styles, graphemes, or hyperlinks)
    // in this row then we go cell by cell and clear them if present.
    if (row.grapheme) {
        for (cells) |*cell| {
            if (cell.hasGrapheme())
                page.clearGrapheme(cell);
        }

        // If we have no left/right scroll region we can be sure
        // that we've cleared all the graphemes, so we clear the
        // flag, otherwise we ask the page to update the flag.
        if (cells.len == page.size.cols) {
            row.grapheme = false;
        } else {
            page.updateRowGraphemeFlag(row);
        }
    }

    if (row.hyperlink) {
        for (cells) |*cell| {
            if (cell.hyperlink)
                page.clearHyperlink(cell);
        }

        // If we have no left/right scroll region we can be sure
        // that we've cleared all the hyperlinks, so we clear the
        // flag, otherwise we ask the page to update the flag.
        if (cells.len == page.size.cols) {
            row.hyperlink = false;
        } else {
            page.updateRowHyperlinkFlag(row);
        }
    }

    if (row.styled) {
        // Styled cells overwhelmingly come in runs sharing the same
        // style (e.g. a colored status bar or a highlighted region),
        // so group them and release each run with a single ref-count
        // update rather than per cell.
        var i: usize = 0;
        while (i < cells.len) {
            const id = cells[i].style_id;
            if (id == style.default_id) {
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < cells.len and cells[j].style_id == id) j += 1;
            page.styles.releaseMultiple(page.memory, id, @intCast(j - i));
            i = j;
        }

        // If we have no left/right scroll region we can be sure
        // that we've cleared all the styles, so we clear the
        // flag, otherwise we ask the page to update the flag.
        if (cells.len == page.size.cols) {
            row.styled = false;
        } else {
            page.updateRowStyledFlag(row);
        }
    }

    {
        if (row.kitty_virtual_placeholder and
            cells.len == page.size.cols)
        {
            for (cells) |c| {
                if (c.codepoint() == kitty.graphics.unicode.placeholder) {
                    break;
                }
            } else row.kitty_virtual_placeholder = false;
        }
    }

    @memset(cells, self.blankCell());
}

/// Clear cells but only if they are not protected.
pub fn clearUnprotectedCells(
    self: *Screen,
    page: *Page,
    row: *Row,
    cells: []Cell,
) void {
    self.accessibility_revision +%= 1;
    var x0: usize = 0;
    var x1: usize = 0;

    while (x0 < cells.len) clear: {
        while (cells[x0].protected) {
            x0 += 1;
            if (x0 >= cells.len) break :clear;
        }
        x1 = x0 + 1;
        while (x1 < cells.len and !cells[x1].protected) {
            x1 += 1;
        }
        self.clearCells(page, row, cells[x0..x1]);
        x0 = x1;
    }

    page.assertIntegrity();
    self.assertIntegrity();
}

/// Clean up boundary conditions where a cell will become discontiguous with
/// a neighboring cell because either one of them will be moved and/or cleared.
///
/// For performance reasons this is specialized to operate on the cursor row.
///
/// Handles the boundary between the cell at `x` and the cell at `x - 1`.
///
/// So, for example, when moving a region of cells [a, b] (inclusive), call this
/// function with `x = a` and `x = b + 1`. It is okay if `x` is out of bounds by
/// 1, this will be interpreted correctly.
///
/// DOES NOT MODIFY ROW WRAP STATE! See `cursorResetWrap` for that.
///
/// The following boundary conditions are handled:
///
/// - `x - 1` is a wide character and `x` is a spacer tail:
///   o Both cells will be cleared.
///   o If `x - 1` is the start of the row and was wrapped from a previous row
///     then the previous row is checked for a spacer head, which is cleared if
///     present.
///
/// - `x == 0` and is a wide character:
///   o If the row is a wrap continuation then the previous row will be checked
///     for a spacer head, which is cleared if present.
///
/// - `x == cols` and `x - 1` is a spacer head:
///   o `x - 1` will be cleared.
///
/// NOTE(qwerasd): This method is not scrolling region aware, and cannot be
/// since it's on Screen not Terminal. This needs to be addressed down the
/// line. Not an extremely urgent issue since it's an edge case of an edge
/// case, but not ideal.
pub fn splitCellBoundary(
    self: *Screen,
    x: size.CellCountInt,
) void {
    self.accessibility_revision +%= 1;
    const page = self.cursor.page_pin.node.page();

    page.pauseIntegrityChecks(true);
    defer page.pauseIntegrityChecks(false);

    const cols = self.cursor.page_pin.node.cols();

    // `x` may be up to an INCLUDING `cols`, since that signifies splitting
    // the boundary to the right of the final cell in the row.
    assert(x <= cols);

    // [ A B C D E F|]
    //              ^ Boundary between final cell and row end.
    if (x == cols) {
        if (!self.cursor.page_row.wrap) return;

        const cells = self.cursor.page_pin.cells(.all);

        // Spacer head at end of wrapped row.
        if (cells[cols - 1].wide == .spacer_head) {
            self.clearCells(
                page,
                self.cursor.page_row,
                cells[cols - 1 ..][0..1],
            );
        }

        return;
    }

    // [|A B C D E F ]
    //  ^ Boundary between first cell and row start.
    //
    //  OR
    //
    // [ A|B C D E F ]
    //    ^ Boundary between first cell and second cell.
    //
    // First cell may be a wrapped wide cell with a spacer
    // head on the previous row that needs to be cleared.
    if ((x == 0 or x == 1) and self.cursor.page_row.wrap_continuation) {
        const cells = self.cursor.page_pin.cells(.all);

        // If the first cell in a row is wide the previous row
        // may have a spacer head which needs to be cleared.
        if (cells[0].wide == .wide) {
            if (self.cursor.page_pin.up(1)) |p_row| {
                const p_rac = p_row.rowAndCell();
                const p_cells = p_row.cells(.all);
                const p_cell = p_cells[p_row.node.cols() - 1];
                if (p_cell.wide == .spacer_head) {
                    self.clearCells(
                        p_row.node.page(),
                        p_rac.row,
                        p_cells[p_row.node.cols() - 1 ..][0..1],
                    );

                    // `clearCells` does not mark rows dirty, and our
                    // callers only mark the cursor row, so mark the
                    // previous row here.
                    p_row.markDirty();
                }
            }
        }
    }

    // If x is 0 then we're done.
    if (x == 0) return;

    // [ ... X|Y ... ]
    //        ^ Boundary between two cells in the middle of the row.
    {
        assert(x > 0);
        assert(x < cols);

        const cells = self.cursor.page_pin.cells(.all);

        const left = cells[x - 1];
        switch (left.wide) {
            // There should not be spacer heads in the middle of the row.
            .spacer_head => unreachable,

            // We don't need to do anything for narrow cells or spacer tails.
            .narrow, .spacer_tail => {},

            // A wide char would be split, so must be cleared.
            .wide => {
                self.clearCells(
                    page,
                    self.cursor.page_row,
                    cells[x - 1 ..][0..2],
                );
            },
        }
    }
}

/// Returns the blank cell to use when doing terminal operations that
/// require preserving the bg color.
pub inline fn blankCell(self: *const Screen) Cell {
    if (self.cursor.style_id == style.default_id) return .{};
    return self.cursor.style.bgCell() orelse .{};
}

pub const Resize = struct {
    /// The new size to resize to
    cols: size.CellCountInt,
    rows: size.CellCountInt,

    /// Whether to reflow soft-wrapped text.
    ///
    /// This will reflow soft-wrapped text. If the screen size is getting
    /// smaller and the maximum scrollback size is exceeded, data will be
    /// lost from the top of the scrollback.
    reflow: bool = true,

    /// Set this to enable prompt redraw on resize. This signals
    /// that the running program can redraw the prompt if the cursor is
    /// currently at a prompt. This detects OSC133 prompts lines and clears
    /// them. If set to `.last`, only the most recent prompt line is cleared.
    prompt_redraw: osc.semantic_prompt.Redraw = .false,

    /// Whether the resize may pull rows out of scrollback back into the
    /// active area. See PageList.Resize for details.
    pull_scrollback: bool = true,
};

const resize_tw = tripwire.module(enum {
    saved_cursor_pin,
    pages,
}, resize);

/// Resize the screen. The rows or cols can be bigger or smaller. If this
/// returns an error, the screen is unchanged.
pub inline fn resize(
    self: *Screen,
    opts: Resize,
) Allocator.Error!void {
    self.accessibility_revision +%= 1;
    const tw = resize_tw;
    defer self.assertIntegrity();

    // We need to insert a tracked pin for our saved cursor so we can
    // modify its X/Y for reflow. Do this before changing any state since
    // tracking the pin can fail.
    const saved_cursor_pin: ?*Pin = saved_cursor: {
        const sc = self.saved_cursor orelse break :saved_cursor null;
        const pin = self.pages.pin(.{ .active = .{
            .x = sc.x,
            .y = sc.y,
        } }) orelse break :saved_cursor null;
        try tw.check(.saved_cursor_pin);
        break :saved_cursor try self.pages.trackPin(pin);
    };
    defer if (saved_cursor_pin) |p| self.pages.untrackPin(p);

    // A cursor style and hyperlink are partly stored in the page containing
    // the cursor. Their IDs only have meaning within that page, and the page
    // keeps reference counts for them. Resizing can replace or destroy the
    // page, so below we temporarily remove both values from the cursor before
    // asking PageList to resize.
    //
    // Save everything first so we can put the cursor back together afterward,
    // or restore it unchanged if the resize fails. We also save the original
    // node and serial so after a successful resize we can tell whether that
    // page survived and still needs its temporary references released.
    const cursor_node = self.cursor.page_pin.node;
    const cursor_node_serial = cursor_node.serial;
    const cursor_style = self.cursor.style;
    const cursor_style_id = self.cursor.style_id;
    const cursor_hyperlink = self.cursor.hyperlink;
    const cursor_hyperlink_id = self.cursor.hyperlink_id;

    // Keep an extra reference to the cursor style and hyperlink while the
    // resize is in progress. Releasing the cursor references below therefore
    // can't delete either entry, and an error can restore the cursor without
    // any allocation.
    {
        const page = cursor_node.page();
        if (cursor_style_id != style.default_id) {
            page.styles.use(page.memory, cursor_style_id);
        }
        if (cursor_hyperlink_id != 0) {
            page.hyperlink_set.use(page.memory, cursor_hyperlink_id);
        }
    }
    errdefer {
        self.cursor.style = cursor_style;
        self.cursor.style_id = cursor_style_id;
        self.cursor.hyperlink = cursor_hyperlink;
        self.cursor.hyperlink_id = cursor_hyperlink_id;
    }

    // Release the cursor style while resizing just in case the cursor ends
    // up on a different page.
    self.cursor.style = .{};
    self.manualStyleUpdate() catch unreachable;

    // If we have a hyperlink, release it from the old page
    // and then we need to re-add it to the new page. This needs
    // to happen because resize below typically reallocates a
    // new page so the old hyperlink is invalid.
    if (self.cursor.hyperlink_id != 0) {
        // Note we do NOT use endHyperlink because we want to keep
        // our allocated self.cursor.hyperlink valid.
        var page = self.cursor.page_pin.node.page();
        page.hyperlink_set.release(page.memory, self.cursor.hyperlink_id);
        self.cursor.hyperlink_id = 0;
        self.cursor.hyperlink = null;
    }

    // Perform the resize operation.
    try tw.check(.pages);
    try self.pages.resize(.{
        .rows = opts.rows,
        .cols = opts.cols,
        .reflow = opts.reflow,
        .cursor = .{
            .x = self.cursor.x,
            .y = self.cursor.y,
            .pin = self.cursor.page_pin,
        },
        .pull_scrollback = opts.pull_scrollback,
    });

    // No more failures are possible after this. Enforced by compiler
    // because we do NO cleanup of the state below.
    errdefer comptime unreachable;

    // Resizing moves image placements, so mark their geometry as dirty.
    self.kitty_images.dirty = true;

    // If we have no scrollback and we shrunk our rows, we must explicitly
    // erase our history. This is because PageList always keeps at least
    // a page size of history.
    if (self.no_scrollback) self.pages.eraseHistory(null);

    // If our cursor was updated, we do a full reload so all our cursor
    // state is correct.
    self.cursorReload();

    // Clear any redrawable prompt after the fallible resize but before
    // restoring the cursor style and hyperlink, so cleared cells retain the
    // same default styling they had with the previous ordering.
    self.clearPromptForRedraw(opts.prompt_redraw);

    // Restore the cursor style.
    self.cursor.style = cursor_style;
    self.manualStyleUpdate() catch |err| {
        // This failure should not happen because manualStyleUpdate handles
        // page splitting, overflow, and more. This should only happen if
        // we're out of RAM. In this case, we'll just degrade gracefully back
        // to the default style.
        log.err("failed to update style on cursor reload err={}", .{err});
        self.cursor.style = .{};
        self.cursor.style_id = 0;
    };

    // If we reflowed a saved cursor, update it.
    if (saved_cursor_pin) |p| {
        // This should never fail because a non-null saved_cursor_pin
        // implies a non-null saved_cursor.
        const sc = &self.saved_cursor.?;
        if (self.pages.pointFromPin(.active, p.*)) |pt| {
            sc.x = @intCast(pt.active.x);
            sc.y = @intCast(pt.active.y);

            // If we had pending wrap set and we're no longer at the end of
            // the line, we unset the pending wrap and move the cursor to
            // reflect the correct next position.
            if (sc.pending_wrap and sc.x != opts.cols - 1) {
                sc.pending_wrap = false;
                sc.x += 1;
            }
        } else {
            // I think this can happen if the screen is resized to be
            // less rows or less cols and our saved cursor moves outside
            // the active area. In this case, there isn't anything really
            // reasonable we can do so we just move the cursor to the
            // top-left. It may be reasonable to also move the cursor to
            // match the primary cursor. Any behavior is fine since this is
            // totally unspecified.
            sc.x = 0;
            sc.y = 0;
            sc.pending_wrap = false;
        }
    }

    // Fix up our hyperlink if we had one.
    if (cursor_hyperlink) |link| {
        self.startHyperlink(link.uri, switch (link.id) {
            .explicit => |v| v,
            .implicit => null,
        }) catch |err| {
            // This shouldn't happen because startHyperlink should handle
            // resizing. This only happens if we're truly out of RAM. Degrade
            // to forgetting the hyperlink.
            log.err("failed to update hyperlink on resize err={}", .{err});
        };

        // Remove our old link
        link.deinit(self.alloc);
        self.alloc.destroy(link);
    }

    // A tracked pin follows its content when PageList moves or replaces a
    // page. If the cursor's pin still points to the node we started with,
    // that node survived the resize and still owns the temporary style and
    // hyperlink references we added above.
    //
    // Comparing pointers is not enough by itself. PageList keeps a pool of
    // nodes, so it can destroy a node and create a replacement at the same
    // memory address. Every new use of a node gets a different serial number,
    // making the pointer-and-serial pair an O(1) identity check.
    const cursor_node_survived =
        self.cursor.page_pin.node == cursor_node and
        self.cursor.page_pin.node.serial == cursor_node_serial;
    if (comptime build_options.slow_runtime_safety) {
        assert(cursor_node_survived ==
            self.pages.nodeIsValid(cursor_node, cursor_node_serial));
    }

    // A surviving node still contains our temporary references, so remove
    // them now. If the node was replaced, its destruction removed those
    // references along with the rest of the old page so we don't need to
    // fix it up.
    if (cursor_node_survived) {
        const page = cursor_node.page();
        if (cursor_style_id != style.default_id) {
            page.styles.release(page.memory, cursor_style_id);
        }
        if (cursor_hyperlink_id != 0) {
            page.hyperlink_set.release(page.memory, cursor_hyperlink_id);
        }
    }
}

fn clearPromptForRedraw(
    self: *Screen,
    redraw: osc.semantic_prompt.Redraw,
) void {
    // If our cursor is on a prompt or input line, clear it so the shell can
    // redraw it. This works with OSC 133 semantic prompts. We do this after
    // the fallible resize so an error leaves the original prompt untouched.
    //
    // We check cursor.semantic_content rather than page_row.semantic_prompt
    // because some shells (e.g., Nu) mark input areas with OSC 133 B but don't
    // mark continuation lines with k=s. If the input spans multiple lines and
    // continuation lines are unmarked, checking only page_row.semantic_prompt
    // would miss them. By checking semantic_content, we assume that if the
    // cursor is on anything other than command output, we're at a prompt/input
    // line and should clear from there.
    if (redraw != .false and
        self.cursor.semantic_content != .output)
    prompt: {
        switch (redraw) {
            .false => unreachable,

            // For `.last`, only clear the current line where the cursor is.
            // For `.true`, clear all prompt lines starting from the beginning.
            .last => {
                const page = self.cursor.page_pin.node.page();
                const row = self.cursor.page_row;
                const cells = page.getCells(row);
                self.clearCells(page, row, cells);
            },

            .true => {
                const start = start: {
                    var it = self.cursor.page_pin.promptIterator(
                        .left_up,
                        null,
                    );
                    break :start it.next() orelse {
                        // This should never happen because promptIterator should always
                        // find a prompt if we already verified our row is some kind of
                        // prompt.
                        log.warn("cursor on prompt line but promptIterator found no prompt", .{});
                        break :prompt;
                    };
                };

                // Clear cells from our start down. We replace it with spaces,
                // and do not physically erase the rows (eraseRows) because the
                // shell is going to expect this space to be available.
                var it = start.rowIterator(.right_down, null);
                while (it.next()) |pin| {
                    const page = pin.node.page();
                    const row = pin.rowAndCell().row;
                    const cells = page.getCells(row);
                    self.clearCells(page, row, cells);
                }
            },
        }
    }
}

/// Set a style attribute for the current cursor.
///
/// If the style can't be set due to any internal errors (memory-related),
/// then this will revert back to the existing style and return an error.
pub fn setAttribute(
    self: *Screen,
    attr: sgr.Attribute,
) PageList.IncreaseCapacityError!void {
    // If we fail to set our style for any reason, we should revert
    // back to the old style. If we fail to do that, we revert back to
    // the default style.
    const old_style = self.cursor.style;
    errdefer {
        self.cursor.style = old_style;
        self.manualStyleUpdate() catch |err| {
            log.warn("setAttribute error restoring old style after failure err={}", .{err});
            self.cursor.style = .{};
            self.manualStyleUpdate() catch unreachable;
        };
    }

    switch (attr) {
        .unset => {
            self.cursor.style = .{};
        },

        .bold => {
            self.cursor.style.flags.bold = true;
        },

        .reset_bold => {
            // Bold and faint share the same SGR code for this
            self.cursor.style.flags.bold = false;
            self.cursor.style.flags.faint = false;
        },

        .italic => {
            self.cursor.style.flags.italic = true;
        },

        .reset_italic => {
            self.cursor.style.flags.italic = false;
        },

        .faint => {
            self.cursor.style.flags.faint = true;
        },

        .underline => |v| {
            self.cursor.style.flags.underline = v;
        },

        .underline_color => |rgb| {
            self.cursor.style.underline_color = .{ .rgb = .{
                .r = rgb.r,
                .g = rgb.g,
                .b = rgb.b,
            } };
        },

        .@"256_underline_color" => |idx| {
            self.cursor.style.underline_color = .{ .palette = idx };
        },

        .reset_underline_color => {
            self.cursor.style.underline_color = .none;
        },

        .overline => {
            self.cursor.style.flags.overline = true;
        },

        .reset_overline => {
            self.cursor.style.flags.overline = false;
        },

        .blink => {
            self.cursor.style.flags.blink = true;
        },

        .reset_blink => {
            self.cursor.style.flags.blink = false;
        },

        .inverse => {
            self.cursor.style.flags.inverse = true;
        },

        .reset_inverse => {
            self.cursor.style.flags.inverse = false;
        },

        .invisible => {
            self.cursor.style.flags.invisible = true;
        },

        .reset_invisible => {
            self.cursor.style.flags.invisible = false;
        },

        .strikethrough => {
            self.cursor.style.flags.strikethrough = true;
        },

        .reset_strikethrough => {
            self.cursor.style.flags.strikethrough = false;
        },

        .direct_color_fg => |rgb| {
            self.cursor.style.fg_color = .{
                .rgb = .{
                    .r = rgb.r,
                    .g = rgb.g,
                    .b = rgb.b,
                },
            };
        },

        .direct_color_bg => |rgb| {
            self.cursor.style.bg_color = .{
                .rgb = .{
                    .r = rgb.r,
                    .g = rgb.g,
                    .b = rgb.b,
                },
            };
        },

        .@"8_fg" => |n| {
            self.cursor.style.fg_color = .{ .palette = @intFromEnum(n) };
        },

        .@"8_bg" => |n| {
            self.cursor.style.bg_color = .{ .palette = @intFromEnum(n) };
        },

        .reset_fg => self.cursor.style.fg_color = .none,

        .reset_bg => self.cursor.style.bg_color = .none,

        .@"8_bright_fg" => |n| {
            self.cursor.style.fg_color = .{ .palette = @intFromEnum(n) };
        },

        .@"8_bright_bg" => |n| {
            self.cursor.style.bg_color = .{ .palette = @intFromEnum(n) };
        },

        .@"256_fg" => |idx| {
            self.cursor.style.fg_color = .{ .palette = idx };
        },

        .@"256_bg" => |idx| {
            self.cursor.style.bg_color = .{ .palette = idx };
        },

        .unknown => return,
    }

    // If the attribute didn't change our style then we can skip the
    // style update entirely: our current style ID is already correct.
    // This is a common case in the wild where programs re-assert the
    // same style repeatedly (e.g. per span or per line).
    if (self.cursor.style.eql(old_style)) return;

    try self.manualStyleUpdate();
}

/// Call this whenever you manually change the cursor style.
///
/// This function can NOT fail if the cursor style is changing to the
/// default style.
///
/// If this returns an error, the style change did not take effect and
/// the cursor style is reverted back to the default. The only scenario
/// this returns an error is if there is a physical memory allocation failure
/// or if there is no possible way to increase style capacity to store
/// the style.
///
/// This function WILL split pages as necessary to accommodate the new style.
/// So if OutOfSpace is returned, it means that even after splitting the page
/// there was still no room for the new style.
pub fn manualStyleUpdate(self: *Screen) PageList.IncreaseCapacityError!void {
    defer self.assertIntegrity();
    var page: *Page = self.cursor.page_pin.node.page();

    // std.log.warn("active styles={}", .{page.styles.count()});

    // Release our previous style if it was not default.
    if (self.cursor.style_id != style.default_id) {
        page.styles.release(page.memory, self.cursor.style_id);
    }

    // If our new style is the default, just reset to that
    if (self.cursor.style.default()) {
        self.cursor.style_id = style.default_id;
        return;
    }

    // Clear the cursor style ID to prevent weird things from happening
    // if the page capacity has to be adjusted which would end up calling
    // manualStyleUpdate again.
    //
    // This also ensures that if anything fails below, we fall back to
    // clearing our style.
    self.cursor.style_id = style.default_id;

    // After setting the style, we need to update our style map.
    // Note that we COULD lazily do this in print. We should look into
    // if that makes a meaningful difference. Our priority is to keep print
    // fast because setting a ton of styles that do nothing is uncommon
    // and weird.
    const id = page.styles.add(
        page.memory,
        self.cursor.style,
    ) catch |err| id: {
        // Our style map is full or needs to be rehashed, so we need to
        // increase style capacity (or rehash).
        const node = self.increaseCapacity(
            self.cursor.page_pin.node,
            switch (err) {
                error.OutOfMemory => .styles,
                error.NeedsRehash => null,
            },
        ) catch |increase_err| switch (increase_err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OutOfSpace => space: {
                // Out of space, we need to split the page. Split wherever
                // is using less capacity and hope that works. If it doesn't
                // work, we tried.
                try self.splitForCapacity(self.cursor.page_pin.*);
                break :space self.cursor.page_pin.node;
            },
        };

        page = node.page();
        break :id page.styles.add(
            page.memory,
            self.cursor.style,
        ) catch |err2| switch (err2) {
            error.OutOfMemory => {
                // This shouldn't happen because increaseCapacity is
                // guaranteed to increase our capacity by at least one and
                // we only need one space, but again, I don't want to crash
                // here so let's log loudly and reset.
                log.err("style addition failed after capacity increase", .{});
                return error.OutOfMemory;
            },
            error.NeedsRehash => {
                // This should be impossible because we rehash above
                // and rehashing should never result in a duplicate. But
                // we don't want to simply hard crash so log it and
                // clear our style.
                log.err("style rehash resulted in needs rehash", .{});
                return;
            },
        };
    };
    errdefer page.styles.release(page.memory, id);

    self.cursor.style_id = id;
}

/// Split at the given pin so that the pinned row moves to the page
/// with less used capacity after the split.
///
/// The primary use case for this is to handle IncreaseCapacityError
/// OutOfSpace conditions where we need to split the page in order
/// to make room for more managed memory.
///
/// If the caller cares about where the pin moves to, they should
/// setup a tracked pin before calling this and then check that.
/// In many calling cases, the input pin is tracked (e.g. the cursor
/// pin).
///
/// If this returns OOM then its a system OOM. If this returns OutOfSpace
/// then it means the page can't be split further.
fn splitForCapacity(
    self: *Screen,
    pin: Pin,
) PageList.SplitError!void {
    // Get our capacities. We include our target row because its
    // capacity will be preserved.
    const bytes_above = Page.layout(pin.node.page().exactRowCapacity(
        0,
        pin.y + 1,
    )).total_size;
    const bytes_below = Page.layout(pin.node.page().exactRowCapacity(
        pin.y,
        pin.node.rows(),
    )).total_size;

    // We need to track the old cursor pin because if our split
    // moves the cursor pin we need to update our accounting.
    const old_cursor = self.cursor.page_pin.*;

    // If our bytes above are less than bytes below, we move the pin
    // to split down one since splitting includes the pinned row in
    // the new node.
    try self.pages.split(if (bytes_above < bytes_below)
        pin.down(1) orelse pin
    else
        pin);

    // Cursor didn't change nodes, we're done.
    if (self.cursor.page_pin.node == old_cursor.node) return;

    // Cursor changed, we need to restore the old pin then use
    // cursorChangePin to move to the new pin. The old node is guaranteed
    // to still exist, just not the row.
    //
    // Note that page_row and all that will be invalid, it points to the
    // new node, but at the time of writing this we don't need any of that
    // to be right in cursorChangePin.
    const new_cursor = self.cursor.page_pin.*;
    self.cursor.page_pin.* = old_cursor;
    self.cursorChangePin(new_cursor);
}

/// Append a grapheme to the given cell within the current cursor row.
pub fn appendGrapheme(
    self: *Screen,
    cell: *Cell,
    cp: u21,
) PageList.IncreaseCapacityError!void {
    self.accessibility_revision +%= 1;
    defer self.cursor.page_pin.node.page().assertIntegrity();
    self.cursor.page_pin.node.page().appendGrapheme(
        self.cursor.page_row,
        cell,
        cp,
    ) catch |err| switch (err) {
        error.OutOfMemory => {
            // We need to determine the actual cell index of the cell so
            // that after we adjust the capacity we can reload the cell.
            const cell_idx: usize = cell_idx: {
                const cells: [*]Cell = @ptrCast(self.cursor.page_cell);
                const zero: [*]Cell = cells - self.cursor.x;
                const target: [*]Cell = @ptrCast(cell);
                const cell_idx = (@intFromPtr(target) - @intFromPtr(zero)) / @sizeOf(Cell);
                break :cell_idx cell_idx;
            };

            // Adjust our capacity. This will update our cursor page pin and
            // force us to reload.
            _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                .grapheme_bytes,
            );

            // The cell pointer is now invalid, so we need to get it from
            // the reloaded cursor pointers.
            const reloaded_cell: *Cell = switch (std.math.order(cell_idx, self.cursor.x)) {
                .eq => self.cursor.page_cell,
                .lt => self.cursorCellLeft(@intCast(self.cursor.x - cell_idx)),
                .gt => self.cursorCellRight(@intCast(cell_idx - self.cursor.x)),
            };

            self.cursor.page_pin.node.page().appendGrapheme(
                self.cursor.page_row,
                reloaded_cell,
                cp,
            ) catch |err2| {
                comptime assert(@TypeOf(err2) == error{OutOfMemory});
                // This should never happen because we just increased capacity.
                // Log loudly but still return an error so we don't just
                // crash.
                log.err("grapheme append failed after capacity increase", .{});
                return err2;
            };
        },
    };
}

/// Start the hyperlink state. Future cells will be marked as hyperlinks with
/// this state. Note that various terminal operations may clear the hyperlink
/// state, such as switching screens (alt screen).
pub fn startHyperlink(
    self: *Screen,
    uri: []const u8,
    id_: ?[]const u8,
) PageList.IncreaseCapacityError!void {
    // Create our pending entry.
    const link: hyperlink.Hyperlink = .{
        .uri = uri,
        .id = if (id_) |id| .{
            .explicit = id,
        } else implicit: {
            defer self.cursor.hyperlink_implicit_id +%= 1;
            break :implicit .{ .implicit = self.cursor.hyperlink_implicit_id };
        },
    };
    errdefer switch (link.id) {
        .explicit => {},
        .implicit => self.cursor.hyperlink_implicit_id -%= 1,
    };

    // Loop until we have enough page memory to add the hyperlink
    while (true) {
        if (self.startHyperlinkOnce(link)) {
            return;
        } else |err| switch (err) {
            // An actual self.alloc OOM is a fatal error.
            error.OutOfMemory => return error.OutOfMemory,

            // strings table is out of memory, adjust it up
            error.StringsOutOfMemory => _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                .string_bytes,
            ),

            // hyperlink set is out of memory, adjust it up
            error.SetOutOfMemory => _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                .hyperlink_bytes,
            ),

            // hyperlink set is too full, rehash it
            error.SetNeedsRehash => _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                null,
            ),
        }

        self.assertIntegrity();
    }
}

/// This is like startHyperlink but if we have to adjust page capacities
/// this returns error.PageAdjusted. This is useful so that we unwind
/// all the previous state and try again.
fn startHyperlinkOnce(
    self: *Screen,
    source: hyperlink.Hyperlink,
) (Allocator.Error || Page.InsertHyperlinkError)!void {
    // Allocate our new Hyperlink entry in non-page memory. This
    // lets us quickly get access to URI, ID.
    const link = try self.alloc.create(hyperlink.Hyperlink);
    errdefer self.alloc.destroy(link);
    link.* = try source.dupe(self.alloc);
    errdefer link.deinit(self.alloc);

    // End any prior hyperlink only after duplicating the new value. The
    // source slices are allowed to reference our current hyperlink.
    self.endHyperlink();

    // Insert the hyperlink into page memory
    var page = self.cursor.page_pin.node.page();
    const id: hyperlink.Id = try page.insertHyperlink(link.*);

    // Save it all
    self.cursor.hyperlink = link;
    self.cursor.hyperlink_id = id;
}

/// End the hyperlink state so that future cells aren't part of the
/// current hyperlink (if any). This is safe to call multiple times.
pub fn endHyperlink(self: *Screen) void {
    // If we have no hyperlink state then do nothing
    if (self.cursor.hyperlink_id == 0) {
        assert(self.cursor.hyperlink == null);
        return;
    }

    // Release the old hyperlink state. If there are cells using the
    // hyperlink this will work because the creation creates a reference
    // and all additional cells create a new reference. This release will
    // just release our initial reference.
    //
    // If the ref count reaches zero the set will not delete the item
    // immediately; it is kept around in case it is used again (this is
    // how RefCountedSet works). This causes some memory fragmentation but
    // is fine because if it is ever pruned the context deleted callback
    // will be called.
    var page: *Page = self.cursor.page_pin.node.page();
    page.hyperlink_set.release(page.memory, self.cursor.hyperlink_id);
    self.cursor.hyperlink.?.deinit(self.alloc);
    self.alloc.destroy(self.cursor.hyperlink.?);
    self.cursor.hyperlink_id = 0;
    self.cursor.hyperlink = null;
}

/// Set the current hyperlink state on the current cell.
pub fn cursorSetHyperlink(self: *Screen) PageList.IncreaseCapacityError!void {
    assert(self.cursor.hyperlink_id != 0);

    var page = self.cursor.page_pin.node.page();
    if (page.setHyperlink(
        self.cursor.page_row,
        self.cursor.page_cell,
        self.cursor.hyperlink_id,
    )) {
        // Success, increase the refcount for the hyperlink.
        page.hyperlink_set.use(page.memory, self.cursor.hyperlink_id);
        return;
    } else |err| switch (err) {
        // hyperlink_map is out of space, realloc the page to be larger
        error.HyperlinkMapOutOfMemory => {
            // Attempt to allocate the space that would be required to
            // insert a new copy of the cursor hyperlink uri in to the
            // string alloc, since right now increaseCapacity always just
            // adds an extra copy even if one already exists in the page.
            // If this alloc fails then we know we also need to grow our
            // string bytes.
            //
            // FIXME: increaseCapacity should not do this.
            while (self.cursor.hyperlink) |link| {
                if (page.string_alloc.alloc(
                    u8,
                    page.memory,
                    link.uri.len,
                )) |slice| {
                    // We don't bother freeing because we're
                    // about to free the entire page anyway.
                    _ = slice;
                    break;
                } else |_| {}

                // We didn't have enough room, let's increase string bytes
                const new_node = try self.increaseCapacity(
                    self.cursor.page_pin.node,
                    .string_bytes,
                );
                assert(new_node == self.cursor.page_pin.node);
                page = new_node.page();
            }

            // The hyperlink map is fixed-capacity, so reaching this error
            // means live entries fill the usable map capacity and the page
            // must grow.
            _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                .hyperlink_bytes,
            );

            // Retry
            //
            // We check that the cursor hyperlink hasn't been destroyed
            // by the capacity adjustment first though- since despite the
            // terrible code above, that can still apparently happen ._.
            if (self.cursor.hyperlink_id > 0) {
                return try self.cursorSetHyperlink();
            }
        },
    }
}

/// Modify the semantic content type of the cursor. This should
/// be preferred over setting it manually since it handles all the
/// proper accounting.
pub fn cursorSetSemanticContent(self: *Screen, t: union(enum) {
    prompt: osc.semantic_prompt.PromptKind,
    output,
    input: enum { clear_explicit, clear_eol },
}) void {
    const cursor = &self.cursor;

    switch (t) {
        .output => {
            cursor.semantic_content = .output;
            cursor.semantic_content_clear_eol = false;
        },

        .input => |clear| {
            cursor.semantic_content = .input;
            cursor.semantic_content_clear_eol = switch (clear) {
                .clear_explicit => false,
                .clear_eol => true,
            };
        },

        .prompt => |kind| {
            self.semantic_prompt.seen = true;
            cursor.semantic_content = .prompt;
            cursor.semantic_content_clear_eol = false;
            cursor.page_row.semantic_prompt = switch (kind) {
                .initial, .right => .prompt,
                .continuation, .secondary => .prompt_continuation,
            };
        },
    }
}

/// Set the selection to the given selection. If this is a tracked selection
/// then the screen will take ownership of the selection. If this is untracked
/// then the screen will convert it to tracked internally. This will automatically
/// untrack the prior selection (if any).
///
/// Set the selection to null to clear any previous selection.
///
/// This is always recommended over setting `selection` directly. Beyond
/// managing memory for you, it also performs safety checks that the selection
/// is always tracked.
pub fn select(self: *Screen, sel_: ?Selection) Allocator.Error!void {
    const sel = sel_ orelse {
        self.clearSelection();
        return;
    };

    // If this selection is untracked then we track it.
    const tracked_sel = if (sel.tracked()) sel else try sel.track(self);
    errdefer if (!sel.tracked()) tracked_sel.deinit(self);

    // Untrack prior selection pins that aren't also owned by the replacement.
    // A caller may pass our current tracked selection back to us by value, so
    // releasing both old pins unconditionally would leave the replacement
    // pointing at freed pool entries.
    if (self.selection) |old| {
        const new_bounds = tracked_sel.bounds.tracked;
        switch (old.bounds) {
            .untracked => old.deinit(self),
            .tracked => |old_bounds| {
                if (old_bounds.start != new_bounds.start and
                    old_bounds.start != new_bounds.end)
                {
                    self.pages.untrackPin(old_bounds.start);
                }
                if (old_bounds.end != new_bounds.start and
                    old_bounds.end != new_bounds.end)
                {
                    self.pages.untrackPin(old_bounds.end);
                }
            },
        }
    }
    self.selection = tracked_sel;
    self.dirty.selection = true;
}

/// Same as select(null) but can't fail.
pub fn clearSelection(self: *Screen) void {
    if (self.selection) |*sel| {
        sel.deinit(self);
        self.dirty.selection = true;
    }
    self.selection = null;
}

pub const SelectionString = struct {
    /// The selection to convert to a string.
    sel: Selection,

    /// If true, trim whitespace around the selection.
    trim: bool = true,
};

/// Returns the raw text associated with a selection. This will unwrap
/// soft-wrapped edges. The returned slice is owned by the caller and allocated
/// using alloc, not the allocator associated with the screen (unless they match).
///
/// For more flexibility, use a ScreenFormatter directly.
pub fn selectionString(
    self: *Screen,
    alloc: Allocator,
    opts: SelectionString,
) Allocator.Error![:0]const u8 {
    return self.selectionStringImpl(alloc, opts, null);
}

/// Returns a StringMap associated with a selection. The map contains the
/// selection's raw text and a mapping from each byte to its screen location.
///
/// The returned map is owned by the caller.
pub fn selectionStringMap(
    self: *Screen,
    alloc: Allocator,
    opts: SelectionString,
) Allocator.Error!StringMap {
    var pins: PinMap.Map = .empty;
    errdefer pins.deinit(alloc);
    return .{
        .string = try self.selectionStringImpl(alloc, opts, &pins),
        .map = pins,
    };
}

fn selectionStringImpl(
    self: *Screen,
    alloc: Allocator,
    opts: SelectionString,
    pins: ?*PinMap.Map,
) Allocator.Error![:0]const u8 {
    // We'll use this as our buffer to build our string.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    // Create a formatter and use that to emit our text.
    var formatter: ScreenFormatter = .init(
        self,
        .{
            .emit = .plain,
            .unwrap = true,
            .trim = opts.trim,
        },
    );
    formatter.content = .{ .selection = opts.sel };

    if (pins) |map| formatter.pin_map = .{
        .alloc = alloc,
        .map = map,
    };

    // Emit. Since this is an allocating writer, a failed write
    // just becomes an OOM.
    formatter.format(&aw.writer) catch return error.OutOfMemory;
    return try aw.toOwnedSliceSentinel(0);
}

// Selection queries do not own or mutate tracked selection state.
const selection_queries = @import("screen/selection.zig");
pub const SelectLine = selection_queries.SelectLine;
pub const selectLine = selection_queries.selectLine;
pub const selectAll = selection_queries.selectAll;
pub const selectWordBetween = selection_queries.selectWordBetween;
pub const selectWord = selection_queries.selectWord;
pub const selectOutput = selection_queries.selectOutput;
pub const LineIterator = selection_queries.LineIterator;
pub const lineIterator = selection_queries.lineIterator;

pub const PromptClickMove = struct {
    left: usize,
    right: usize,

    pub const zero = PromptClickMove{
        .left = 0,
        .right = 0,
    };
};

/// Determine the inputs necessary to move the cursor to the given
/// click location within a prompt input area.
///
/// If the cursor isn't currently at a prompt input location, this
/// returns no movement.
///
/// This feature depends on well-behaved OSC133 shell integration. Specifically,
/// this only moves over designated input areas (OSC 133 B). It is assumed
/// that the shell will only move the cursor to input cells, so prompt cells
/// and other blank cells are ignored as part of the movement calculation.
pub fn promptClickMove(
    self: *Screen,
    click_pin: Pin,
) PromptClickMove {
    // If we're not at an input cell with our cursor, no movement will
    // ever be possible.
    if (self.cursor.semantic_content != .input and
        self.cursor.page_cell.semantic_content != .input) return .zero;

    return switch (self.semantic_prompt.click) {
        // None doesn't support movement and click_events must use a
        // different mechanism (SGR mouse events) that callers must handle.
        .none, .click_events => .zero,
        .cl => |cl| switch (cl) {
            // All of these currently use dumb line-based navigation.
            // But eventually we'll support more.
            .line,
            .multiple,
            .conservative_vertical,
            .smart_vertical,
            => self.promptClickLine(click_pin),
        },
    };
}

/// Determine the inputs required to move from the cursor to the given
/// click location. If the cursor isn't currently at a prompt input
/// location, this will return zero.
///
/// This currently only supports moving a single line.
fn promptClickLine(self: *Screen, click_pin: Pin) PromptClickMove {
    // If our click pin is our cursor pin, no movement is needed.
    // Do this early so we can assume later that they are different.
    const cursor_pin = self.cursor.page_pin.*;
    if (cursor_pin.eql(click_pin)) return .zero;

    // If our cursor is before our click, we're only emitting right inputs.
    if (cursor_pin.before(click_pin)) {
        var count: usize = 0;

        // We go row-by-row because soft-wrapped rows are still a single
        // line to a shell, so we can't just look at our page row.
        var row_it = cursor_pin.rowIterator(
            .right_down,
            click_pin,
        );
        row_it: while (row_it.next()) |row_pin| {
            const rac = row_pin.rowAndCell();
            const cells = row_pin.node.page().getCells(rac.row);

            // Determine if this row is our cursor.
            const is_cursor_row = row_pin.node == cursor_pin.node and
                row_pin.y == cursor_pin.y;

            // If this is not the cursor row, verify it's still part of the
            // continuation of our starting prompt.
            if (!is_cursor_row and
                rac.row.semantic_prompt != .prompt_continuation) break;

            // Determine where our input starts.
            const start_x: usize = start_x: {
                // If this is our cursor row then we start after the cursor.
                if (is_cursor_row) break :start_x cursor_pin.x + 1;

                // Otherwise, we start at the first input cell, because
                // we expect the shell to properly translate arrows across
                // lines to the start of the input. Some shells indent
                // where input starts on subsequent lines so we must do
                // this.
                for (cells, 0..) |cell, x| {
                    if (cell.semantic_content == .input) break :start_x x;
                }

                // We never found an input cell, so we need to move to the
                // next row.
                break :start_x cells.len;
            };

            // Iterate over the input cells and assume arrow keys only
            // jump to input cells.
            for (cells[start_x..], start_x..) |cell, x| {
                // Ignore non-input cells, but allow breaks. We assume
                // the shell will translate arrow keys to only input
                // areas.
                if (cell.semantic_content != .input) continue;

                // Increment our input count
                count += 1;

                // If this is our target, we're done.
                if (row_pin.node == click_pin.node and
                    row_pin.y == click_pin.y and
                    x == click_pin.x)
                    break :row_it;
            }

            // If this row isn't soft-wrapped, we need to break out
            // because line based moving only handles single lines.
            // We're done!
            if (!rac.row.wrap) {
                // If we never found our pin, that means we clicked further
                // right/beyond it. If we're already on a non-empty input cell
                // then we add one so we can move to the newest, empty cell
                // at the end, matching typical editor behavior.
                if (self.cursor.page_cell.semantic_content == .input) count += 1;

                break;
            }
        }

        return .{ .left = 0, .right = count };
    }

    // Otherwise, cursor is after click, so we're emitting left inputs.
    var count: usize = 0;

    // We go row-by-row because soft-wrapped rows are still a single
    // line to a shell, so we can't just look at our page row.
    var row_it = cursor_pin.rowIterator(
        .left_up,
        click_pin,
    );
    row_it: while (row_it.next()) |row_pin| {
        const rac = row_pin.rowAndCell();
        const cells = row_pin.node.page().getCells(rac.row);

        // Determine the length of the cells we look at in this row.
        const end_len: usize = end_len: {
            // If this is our cursor row then we end before the cursor.
            if (row_pin.node == cursor_pin.node and
                row_pin.y == cursor_pin.y) break :end_len cursor_pin.x;

            // Otherwise, we end at the last cell in the row.
            break :end_len cells.len;
        };

        // Iterate backwards over the input cells.
        for (0..end_len) |rev_x| {
            const x: usize = end_len - 1 - rev_x;
            const cell = cells[x];

            // Ignore non-input cells.
            if (cell.semantic_content != .input) continue;

            // Increment our input count
            count += 1;

            // If this is our target, we're done.
            if (row_pin.node == click_pin.node and
                row_pin.y == click_pin.y and
                x == click_pin.x)
                break :row_it;
        }

        // If this row is not a wrap continuation, then break out
        if (!rac.row.wrap_continuation) break;
    }

    return .{ .left = count, .right = 0 };
}

/// Dump the screen to a string. The writer given should be buffered;
/// this function does not attempt to efficiently write and generally writes
/// one byte at a time.
pub fn dumpString(
    self: *const Screen,
    writer: *std.Io.Writer,
    opts: struct {
        /// The start and end points of the dump, both inclusive. The x will
        /// be ignored and the full row will always be dumped.
        tl: Pin,
        br: ?Pin = null,

        /// If true, this will unwrap soft-wrapped lines. If false, this will
        /// dump the screen as it is visually seen in a rendered window.
        unwrap: bool = true,
    },
) std.Io.Writer.Error!void {
    // Create a formatter and use that to emit our text.
    var formatter: ScreenFormatter = .init(self, .{
        .emit = .plain,
        .unwrap = opts.unwrap,
        .trim = false,
    });

    // Set up the selection based on the pins
    const tl = opts.tl;
    const br = opts.br orelse self.pages.getBottomRight(.screen).?;

    formatter.content = .{
        .selection = Selection.init(
            tl,
            br,
            false, // not rectangle
        ),
    };

    // Emit
    try formatter.format(writer);
}

/// You should use dumpString, this is a restricted version mostly for
/// legacy and convenience reasons for unit tests.
pub fn dumpStringAlloc(
    self: *const Screen,
    alloc: Allocator,
    tl: point.Point,
) ![]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    try self.dumpString(&builder.writer, .{
        .tl = self.pages.getTopLeft(tl),
        .br = self.pages.getBottomRight(tl) orelse return error.UnknownPoint,
        .unwrap = false,
    });

    return try builder.toOwnedSlice();
}

/// You should use dumpString, this is a restricted version mostly for
/// legacy and convenience reasons for unit tests.
pub fn dumpStringAllocUnwrapped(
    self: *const Screen,
    alloc: Allocator,
    tl: point.Point,
) ![]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    try self.dumpString(&builder.writer, .{
        .tl = self.pages.getTopLeft(tl),
        .br = self.pages.getBottomRight(tl) orelse return error.UnknownPoint,
        .unwrap = true,
    });

    return try builder.toOwnedSlice();
}

/// This is basically a really jank version of Terminal.printString. We
/// have to reimplement it here because we want a way to print to the screen
/// to test it but don't want all the features of Terminal.
pub fn testWriteString(self: *Screen, text: []const u8) !void {
    self.accessibility_revision +%= 1;
    const view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |c| {
        // Explicit newline forces a new row
        if (c == '\n') {
            try self.cursorDownOrScroll();
            self.cursorHorizontalAbsolute(0);
            self.cursor.pending_wrap = false;
            if (self.cursor.semantic_content_clear_eol) {
                self.cursorSetSemanticContent(.output);
            } else switch (self.cursor.semantic_content) {
                .output => {},
                .prompt, .input => self.cursor.page_row.semantic_prompt = .prompt_continuation,
            }
            continue;
        }

        const width: usize = if (c <= 0xFF) 1 else @intCast(unicode.table.get(c).width);
        if (width == 0) {
            const cell = cell: {
                var cell = self.cursorCellLeft(1);
                switch (cell.wide) {
                    .narrow => {},
                    .wide => {},
                    .spacer_head => unreachable,
                    .spacer_tail => cell = self.cursorCellLeft(2),
                }

                break :cell cell;
            };

            try self.cursor.page_pin.node.page().appendGrapheme(
                self.cursor.page_row,
                cell,
                c,
            );
            continue;
        }

        if (self.cursor.pending_wrap) {
            assert(self.cursor.x == self.pages.cols - 1);
            self.cursor.pending_wrap = false;
            self.cursor.page_row.wrap = true;
            try self.cursorDownOrScroll();
            self.cursorHorizontalAbsolute(0);
            self.cursor.page_row.wrap_continuation = true;
            switch (self.cursor.semantic_content) {
                .output => {},
                .input, .prompt => self.cursor.page_row.semantic_prompt = .prompt_continuation,
            }
        }

        assert(width == 1 or width == 2);
        switch (width) {
            1 => {
                self.cursor.page_cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = @bitCast(@as(u24, @intCast(c))) },
                    .style_id = self.cursor.style_id,
                    .protected = self.cursor.protected,
                    .semantic_content = self.cursor.semantic_content,
                };

                // If we have a ref-counted style, increase.
                if (self.cursor.style_id != style.default_id) {
                    const page = self.cursor.page_pin.node.page();
                    page.styles.use(page.memory, self.cursor.style_id);
                    self.cursor.page_row.styled = true;
                }

                // If we have a hyperlink, add it to the cell.
                if (self.cursor.hyperlink_id > 0) try self.cursorSetHyperlink();
            },

            2 => {
                // Need a wide spacer head
                if (self.cursor.x == self.pages.cols - 1) {
                    self.cursor.page_cell.* = .{
                        .content_tag = .codepoint,
                        .content = .{ .codepoint = .{ .data = 0 } },
                        .wide = .spacer_head,
                        .protected = self.cursor.protected,
                        .semantic_content = self.cursor.semantic_content,
                    };

                    // If we have a hyperlink, add it to the cell.
                    if (self.cursor.hyperlink_id > 0) try self.cursorSetHyperlink();

                    self.cursor.page_row.wrap = true;
                    try self.cursorDownOrScroll();
                    self.cursorHorizontalAbsolute(0);
                    self.cursor.page_row.wrap_continuation = true;
                }

                // Write our wide char
                self.cursor.page_cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = c } },
                    .style_id = self.cursor.style_id,
                    .wide = .wide,
                    .protected = self.cursor.protected,
                    .semantic_content = self.cursor.semantic_content,
                };

                // If we have a hyperlink, add it to the cell.
                if (self.cursor.hyperlink_id > 0) try self.cursorSetHyperlink();

                // Write our tail
                self.cursorRight(1);
                self.cursor.page_cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = 0 } },
                    .wide = .spacer_tail,
                    .protected = self.cursor.protected,
                    .semantic_content = self.cursor.semantic_content,
                };

                // If we have a hyperlink, add it to the cell.
                if (self.cursor.hyperlink_id > 0) try self.cursorSetHyperlink();

                // If we have a ref-counted style, increase twice.
                if (self.cursor.style_id != style.default_id) {
                    const page = self.cursor.page_pin.node.page();
                    page.styles.use(page.memory, self.cursor.style_id);
                    page.styles.use(page.memory, self.cursor.style_id);
                    self.cursor.page_row.styled = true;
                }
            },

            else => unreachable,
        }

        if (self.cursor.x + 1 < self.pages.cols) {
            self.cursorRight(1);
        } else {
            self.cursor.pending_wrap = true;
        }
    }
}

/// White-box regression hooks; absent from application builds.
pub const TestAccess = if (@import("builtin").is_test) struct {
    pub const cursorDownOrScroll = Screen.cursorDownOrScroll;

    pub const resize_tw = Screen.resize_tw;
} else struct {};

test {
    _ = @import("tests/Screen/cursor.zig");
    _ = @import("tests/Screen/operations.zig");
    _ = @import("tests/Screen/resize.zig");
    _ = @import("tests/Screen/attributes.zig");
    _ = @import("tests/Screen/selection.zig");
}
