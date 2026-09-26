//! Stable page coordinates and traversal. PageList owns tracked pin lifetime.
const Pin = @This();
const std = @import("std");
const build_options = @import("terminal_options");
const assert = @import("../../quirks.zig").inlineAssert;
const PageList = @import("../PageList.zig");
const pagepkg = @import("../page.zig");
const stylepkg = @import("../style.zig");
const size = @import("../size.zig");
const List = PageList.List;
const Direction = PageList.Direction;
const PromptIterator = PageList.PromptIterator;
const CellIterator = PageList.CellIterator;
const RowIterator = PageList.RowIterator;
const PageIterator = PageList.PageIterator;

node: *List.Node,
y: size.CellCountInt = 0,
x: size.CellCountInt = 0,

/// This is flipped to true for tracked pins that were tracking
/// a page that got pruned for any reason and where the tracked pin
/// couldn't be moved to a sensical location. Users of the tracked
/// pin could use this data and make their own determination of
/// semantics.
garbage: bool = false,

pub inline fn rowAndCell(self: Pin) struct {
    row: *pagepkg.Row,
    cell: *pagepkg.Cell,
} {
    const rac = self.node.page().getRowAndCell(self.x, self.y);
    return .{ .row = rac.row, .cell = rac.cell };
}

pub const CellSubset = enum { all, left, right };

/// Returns the cells for the row that this pin is on. The subset determines
/// what subset of the cells are returned. The "left/right" subsets are
/// inclusive of the x coordinate of the pin.
pub inline fn cells(self: Pin, subset: CellSubset) []pagepkg.Cell {
    const page = self.node.page();
    const rac = page.getRowAndCell(self.x, self.y);
    const all = page.getCells(rac.row);
    return switch (subset) {
        .all => all,
        .left => all[0 .. self.x + 1],
        .right => all[self.x..],
    };
}

/// Returns the grapheme codepoints for the given cell. These are only
/// the EXTRA codepoints and not the first codepoint.
pub inline fn grapheme(self: Pin, cell: *const pagepkg.Cell) ?[]u21 {
    return self.node.page().lookupGrapheme(cell);
}

/// Returns the style for the given cell in this pin.
pub inline fn style(self: Pin, cell: *const pagepkg.Cell) stylepkg.Style {
    if (cell.style_id == stylepkg.default_id) return .{};
    const page = self.node.page();
    return page.styles.get(
        page.memory,
        cell.style_id,
    ).*;
}

/// Check if this pin is dirty.
pub inline fn isDirty(self: Pin) bool {
    const page = self.node.page();
    return page.dirty or page.getRowAndCell(self.x, self.y).row.dirty;
}

/// Mark this pin location as dirty.
pub inline fn markDirty(self: Pin) void {
    self.rowAndCell().row.dirty = true;
}

/// Iterators. These are the same as PageList iterator funcs but operate
/// on pins rather than points. This is MUCH more efficient than calling
/// pointFromPin and building up the iterator from points.
///
/// The limit pin is inclusive.
pub inline fn pageIterator(
    self: Pin,
    direction: Direction,
    limit: ?Pin,
) PageIterator {
    if (build_options.slow_runtime_safety) {
        if (limit) |l| {
            // Check the order according to the iteration direction.
            switch (direction) {
                .right_down => assert(self.eql(l) or self.before(l)),
                .left_up => assert(self.eql(l) or l.before(self)),
            }
        }
    }

    return .{
        .row = self,
        .limit = if (limit) |p| .{ .row = p } else .{ .none = {} },
        .direction = direction,
    };
}

pub inline fn rowIterator(
    self: Pin,
    direction: Direction,
    limit: ?Pin,
) RowIterator {
    var page_it = self.pageIterator(direction, limit);
    const chunk = page_it.next() orelse return .{ .page_it = page_it };
    return .{
        .page_it = page_it,
        .chunk = chunk,
        .offset = switch (direction) {
            .right_down => chunk.start,
            .left_up => chunk.end - 1,
        },
    };
}

pub inline fn cellIterator(
    self: Pin,
    direction: Direction,
    limit: ?Pin,
) CellIterator {
    var row_it = self.rowIterator(direction, limit);
    var cell = row_it.next() orelse return .{ .row_it = row_it };
    cell.x = self.x;
    return .{ .row_it = row_it, .cell = cell };
}

pub inline fn promptIterator(
    self: Pin,
    direction: Direction,
    limit: ?Pin,
) PromptIterator {
    return .{
        .current = self,
        .limit = limit,
        .direction = direction,
    };
}

/// Returns true if this pin is between the top and bottom, inclusive.
//
// Note: this is primarily unit tested as part of the Kitty
// graphics deletion code.
pub fn isBetween(self: Pin, top: Pin, bottom: Pin) bool {
    if (build_options.slow_runtime_safety) {
        if (top.node == bottom.node) {
            // If top is bottom, must be ordered.
            assert(top.y <= bottom.y);
            if (top.y == bottom.y) {
                assert(top.x <= bottom.x);
            }
        } else {
            // If top is not bottom, top must be before bottom.
            var node_ = top.node.next;
            while (node_) |node| : (node_ = node.next) {
                if (node == bottom.node) break;
            } else assert(false);
        }
    }

    if (self.node == top.node) {
        // If our pin is the top page and our y is less than the top y
        // then we can't possibly be between the top and bottom.
        if (self.y < top.y) return false;

        // If our y is after the top y but we're on the same page
        // then we're between the top and bottom if our y is less
        // than or equal to the bottom y if its the same page. If the
        // bottom is another page then it means that the range is
        // at least the full top page and since we're the same page
        // we're in the range.
        if (self.y > top.y) {
            return if (self.node == bottom.node)
                self.y <= bottom.y
            else
                true;
        }

        // Otherwise our y is the same as the top y, so we need to
        // check the x coordinate.
        assert(self.y == top.y);
        if (self.x < top.x) return false;
    }
    if (self.node == bottom.node) {
        // Our page is the bottom page so we're between the top and
        // bottom if our y is less than the bottom y.
        if (self.y > bottom.y) return false;
        if (self.y < bottom.y) return true;

        // If our y is the same, then we're between if we're before
        // or equal to the bottom x.
        assert(self.y == bottom.y);
        return self.x <= bottom.x;
    }

    // Our page isn't the top or bottom so we need to check if
    // our page is somewhere between the top and bottom.

    // Since our loop starts at top.page.next we need to check that
    // top != bottom because if they're the same then we can't possibly
    // be between them.
    if (top.node == bottom.node) return false;
    var node_ = top.node.next;
    while (node_) |node| : (node_ = node.next) {
        if (node == bottom.node) break;
        if (node == self.node) return true;
    }

    return false;
}

/// Returns true if self is before other. This is very expensive since
/// it requires traversing the linked list of pages. This should not
/// be called in performance critical paths.
pub fn before(self: Pin, other: Pin) bool {
    if (self.node == other.node) {
        if (self.y < other.y) return true;
        if (self.y > other.y) return false;
        return self.x < other.x;
    }

    var node_ = self.node.next;
    while (node_) |node| : (node_ = node.next) {
        if (node == other.node) return true;
    }

    return false;
}

pub inline fn eql(self: Pin, other: Pin) bool {
    return self.node == other.node and
        self.y == other.y and
        self.x == other.x;
}

/// Move the pin left n columns. n must fit within the size.
pub inline fn left(self: Pin, n: usize) Pin {
    assert(n <= self.x);
    var result = self;
    result.x -= std.math.cast(size.CellCountInt, n) orelse result.x;
    return result;
}

/// Move the pin right n columns. n must fit within the size.
pub inline fn right(self: Pin, n: usize) Pin {
    assert(self.x + n < self.node.cols());
    var result = self;
    result.x +|= std.math.cast(size.CellCountInt, n) orelse
        std.math.maxInt(size.CellCountInt);
    return result;
}

/// Move the pin left n columns, stopping at the start of the row.
pub inline fn leftClamp(self: Pin, n: size.CellCountInt) Pin {
    var result = self;
    result.x -|= n;
    return result;
}

/// Move the pin right n columns, stopping at the end of the row.
pub inline fn rightClamp(self: Pin, n: size.CellCountInt) Pin {
    var result = self;
    result.x = @min(self.x +| n, self.node.cols() - 1);
    return result;
}

/// Move the pin left n cells, wrapping to the previous row as needed.
///
/// If the offset goes beyond the top of the screen, returns null.
///
/// TODO: Unit tests.
pub fn leftWrap(self: Pin, n: usize) ?Pin {
    var result = self;
    var remaining = n;
    while (remaining > result.x) {
        remaining -= @as(usize, result.x) + 1;
        result = result.up(1) orelse return null;
        // Crossing a row boundary lands on that destination row's final
        // cell, whose width may differ from ours during reflow.
        result.x = result.node.cols() - 1;
    }

    result.x -= @intCast(remaining);
    return result;
}

/// Move the pin right n cells, wrapping to the next row as needed.
///
/// If the offset goes beyond the bottom of the screen, returns null.
///
/// TODO: Unit tests.
pub fn rightWrap(self: Pin, n: usize) ?Pin {
    var result = self;
    var remaining = n;
    while (true) {
        const row_remaining = result.node.cols() - result.x - 1;
        if (remaining <= row_remaining) {
            result.x += @intCast(remaining);
            return result;
        }

        remaining -= @as(usize, row_remaining) + 1;
        result = result.down(1) orelse return null;
        result.x = 0;
    }
}

/// Move the pin down a certain number of rows, or return null if
/// the pin goes beyond the end of the screen.
pub inline fn down(self: Pin, n: usize) ?Pin {
    return switch (self.downOverflow(n)) {
        .offset => |v| v,
        .overflow => null,
    };
}

/// Move the pin up a certain number of rows, or return null if
/// the pin goes beyond the start of the screen.
pub inline fn up(self: Pin, n: usize) ?Pin {
    return switch (self.upOverflow(n)) {
        .offset => |v| v,
        .overflow => null,
    };
}

/// Move the offset down n rows. If the offset goes beyond the
/// end of the screen, return the overflow amount.
pub fn downOverflow(self: Pin, n: usize) union(enum) {
    offset: Pin,
    overflow: struct {
        end: Pin,
        remaining: usize,
    },
} {
    // Index fits within this page
    const rows = self.node.rows() - (self.y + 1);
    if (n <= rows) return .{ .offset = .{
        .node = self.node,
        .y = std.math.cast(size.CellCountInt, self.y + n) orelse
            std.math.maxInt(size.CellCountInt),
        .x = self.x,
    } };

    // Need to traverse page links to find the page
    var node: *List.Node = self.node;
    var n_left: usize = n - rows;
    while (true) {
        node = node.next orelse return .{ .overflow = .{
            .end = .{
                .node = node,
                .y = node.rows() - 1,
                .x = @min(self.x, node.cols() - 1),
            },
            .remaining = n_left,
        } };
        if (n_left <= node.rows()) return .{ .offset = .{
            .node = node,
            .y = std.math.cast(size.CellCountInt, n_left - 1) orelse
                std.math.maxInt(size.CellCountInt),
            .x = @min(self.x, node.cols() - 1),
        } };
        n_left -= node.rows();
    }
}

/// Move the offset up n rows. If the offset goes beyond the
/// start of the screen, return the overflow amount.
pub fn upOverflow(self: Pin, n: usize) union(enum) {
    offset: Pin,
    overflow: struct {
        end: Pin,
        remaining: usize,
    },
} {
    // Index fits within this page
    if (n <= self.y) return .{ .offset = .{
        .node = self.node,
        .y = std.math.cast(size.CellCountInt, self.y - n) orelse
            std.math.maxInt(size.CellCountInt),
        .x = self.x,
    } };

    // Need to traverse page links to find the page
    var node: *List.Node = self.node;
    var n_left: usize = n - self.y;
    while (true) {
        node = node.prev orelse return .{ .overflow = .{
            .end = .{
                .node = node,
                .y = 0,
                .x = @min(self.x, node.cols() - 1),
            },
            .remaining = n_left,
        } };
        if (n_left <= node.rows()) return .{ .offset = .{
            .node = node,
            .y = std.math.cast(size.CellCountInt, node.rows() - n_left) orelse
                std.math.maxInt(size.CellCountInt),
            .x = @min(self.x, node.cols() - 1),
        } };
        n_left -= node.rows();
    }
}
